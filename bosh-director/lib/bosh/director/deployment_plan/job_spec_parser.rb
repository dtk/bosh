require 'bosh/template/property_helper'

module Bosh::Director
  module DeploymentPlan
    class JobSpecParser
      include ValidationHelper
      include Bosh::Template::PropertyHelper
      include IpUtil

      # @param [Bosh::Director::DeploymentPlan] deployment Deployment plan
      def initialize(deployment, event_log, logger)
        @deployment = deployment
        @event_log = event_log
        @logger = logger
      end

      # @param [Hash] job_spec Raw job spec from the deployment manifest
      # @return [DeploymentPlan::Job] Job as build from job_spec
      def parse(job_spec)
        @job_spec = job_spec
        @job = Job.new(@logger)

        parse_name
        parse_lifecycle

        parse_release
        validate_templates

        parse_template
        parse_templates

        check_template_uniqueness
        parse_disk
        parse_properties
        parse_resource_pool
        parse_update_config

        networks = JobNetworksParser.new(Network::VALID_DEFAULTS).parse(@job_spec, @job.name, @deployment.networks)
        @job.networks = networks
        assign_default_networks(networks)

        availability_zones = JobAvailabilityZoneParser.new.parse(@job_spec, @job, @deployment, networks)
        @job.availability_zones = availability_zones

        parse_migrated_from

        desired_instances = parse_desired_instances(availability_zones, networks)
        @job.desired_instances = desired_instances

        @job
      end

      private

      def parse_name
        @job.name = safe_property(@job_spec, "name", :class => String)
        @job.canonical_name = Canonicalizer.canonicalize(@job.name)
      end

      def parse_lifecycle
        lifecycle = safe_property(@job_spec, "lifecycle",
          :class => String,
          :optional => true,
          :default => Job::DEFAULT_LIFECYCLE_PROFILE,
        )

        unless Job::VALID_LIFECYCLE_PROFILES.include?(lifecycle)
          raise JobInvalidLifecycle,
            "Invalid lifecycle `#{lifecycle}' for `#{@job.name}', " +
            "valid lifecycle profiles are: #{Job::VALID_LIFECYCLE_PROFILES.join(', ')}"
        end

        @job.lifecycle = lifecycle
      end

      def parse_release
        release_name = safe_property(@job_spec, "release", :class => String, :optional => true)

        if release_name.nil?
          if @deployment.releases.size == 1
            @job.release = @deployment.releases.first
          end
        else
          @job.release = @deployment.release(release_name)

          if @job.release.nil?
            raise JobUnknownRelease,
                  "Job `#{@job.name}' references an unknown release `#{release_name}'"
          end
        end
      end

      def parse_template
        template_names = safe_property(@job_spec, "template", optional: true)
        if template_names
          if template_names.is_a?(Array)
            @event_log.warn_deprecated(
              "Please use `templates' when specifying multiple templates for a job. " +
              "`template' for multiple templates will soon be unsupported."
            )
          end

          unless template_names.is_a?(Array) || template_names.is_a?(String)
            invalid_type("template", "String or Array", template_names)
          end

          unless @job.release
            raise JobMissingRelease, "Cannot tell what release job `#{@job.name}' is supposed to use, please explicitly specify one"
          end

          Array(template_names).each do |template_name|
            @job.templates << @job.release.get_or_create_template(template_name)
          end
        end
      end

      def parse_templates
        templates = safe_property(@job_spec, 'templates', class: Array, optional: true)

        if templates
          templates.each do |template_spec|
            template_name = safe_property(template_spec, 'name', class: String)
            release_name = safe_property(template_spec, 'release', class: String, optional: true)

            if release_name
              release = @deployment.release(release_name)
              unless release
                raise JobUnknownRelease,
                      "Template `#{template_name}' (job `#{@job.name}') references an unknown release `#{release_name}'"
              end
            else
              release = @job.release
              unless release
                raise JobMissingRelease, "Cannot tell what release template `#{template_name}' (job `#{@job.name}') is supposed to use, please explicitly specify one"
              end
            end

            @job.templates << release.get_or_create_template(template_name)

            links = safe_property(template_spec, 'links', class: Hash, optional: true)
            @logger.debug("Parsing template links: #{links.inspect}")

            links.to_a.each do |name, path|
              link_path = LinkPath.parse(@deployment.name, path, @logger)
              @job.add_link_path(template_name, name, link_path)
            end
          end
        end
      end

      def check_template_uniqueness
        all_names = @job.templates.map(&:name)
        @job.templates.each do |template|
          if all_names.count(template.name) > 1
            raise JobInvalidTemplates,
                  "Colocated job template `#{template.name}' has the same name in multiple releases. " +
                  "BOSH cannot currently colocate two job templates with identical names from separate releases."
          end
        end
      end

      def parse_disk
        disk_size = safe_property(@job_spec, 'persistent_disk', :class => Integer, :optional => true)
        disk_type_name = safe_property(@job_spec, 'persistent_disk_type', :class => String, :optional => true)
        disk_pool_name = safe_property(@job_spec, 'persistent_disk_pool', :class => String, :optional => true)

        if disk_type_name && disk_pool_name
          raise JobInvalidPersistentDisk,
            "Job `#{@job.name}' specifies both 'disk_types' and 'disk_pools', only one key is allowed. " +
              "'disk_pools' key will be DEPRECATED in the future."
        end

        if disk_type_name
          disk_name = disk_type_name
          disk_source = 'type'
        else
          disk_name = disk_pool_name
          disk_source = 'pool'
        end

        if disk_size && disk_name
          raise JobInvalidPersistentDisk,
            "Job `#{@job.name}' references both a persistent disk size `#{disk_size}' " +
              "and a persistent disk #{disk_source} `#{disk_name}'"
        end

        if disk_size
          if disk_size < 0
            raise JobInvalidPersistentDisk,
              "Job `#{@job.name}' references an invalid persistent disk size `#{disk_size}'"
          else
            @job.persistent_disk = disk_size
          end
        end

        if disk_name
          disk_type = @deployment.disk_type(disk_name)
          if disk_type.nil?
            raise JobUnknownDiskType,
                  "Job `#{@job.name}' references an unknown disk #{disk_source} `#{disk_name}'"
          else
            @job.persistent_disk_type = disk_type
          end
        end
      end

      def parse_properties
        # Manifest can contain global and per-job properties section
        job_properties = safe_property(@job_spec, "properties", :class => Hash, :optional => true, :default => {})

        @job.all_properties = @deployment.properties.recursive_merge(job_properties)

        mappings = safe_property(@job_spec, "property_mappings", :class => Hash, :default => {})

        mappings.each_pair do |to, from|
          resolved = lookup_property(@job.all_properties, from)

          if resolved.nil?
            raise JobInvalidPropertyMapping,
                  "Cannot satisfy property mapping `#{to}: #{from}', as `#{from}' is not in deployment properties"
          end

          @job.all_properties[to] = resolved
        end
      end

      def parse_resource_pool
        env_hash = safe_property(@job_spec, 'env', class: Hash, :default => {})
        resource_pool_name = safe_property(@job_spec, "resource_pool", class: String, optional: true)

        if resource_pool_name
          resource_pool = @deployment.resource_pool(resource_pool_name)
          if resource_pool.nil?
            raise JobUnknownResourcePool,
              "Job `#{@job.name}' references an unknown resource pool `#{resource_pool_name}'"
          end

          vm_type = VmType.new({
            'name' => resource_pool.name,
            'cloud_properties' => resource_pool.cloud_properties
          })

          stemcell = resource_pool.stemcell

          if !env_hash.empty? && !resource_pool.env.empty?
            raise JobAmbiguousEnv,
              "Job '#{@job.name}' and resource pool: '#{resource_pool_name}' both declare env properties"
          end

          if env_hash.empty?
            env_hash = resource_pool.env
          end
        else
          vm_type_name = safe_property(@job_spec, 'vm_type', class: String)
          vm_type = @deployment.vm_type(vm_type_name)
          if vm_type.nil?
            raise JobUnknownVmType,
              "Job `#{@job.name}' references an unknown vm type `#{vm_type_name}'"
          end

          stemcell_name = safe_property(@job_spec, 'stemcell', class: String)
          stemcell = @deployment.stemcell(stemcell_name)
          if stemcell.nil?
            raise JobUnknownStemcell,
              "Job `#{@job.name}' references an unknown stemcell `#{stemcell_name}'"
          end
        end

        @job.vm_type = vm_type
        @job.stemcell = stemcell
        @job.env = Env.new(env_hash)
      end

      def parse_update_config
        update_spec = safe_property(@job_spec, "update", class: Hash, optional: true)
        @job.update = UpdateConfig.new(update_spec, @deployment.update)
      end

      def parse_desired_instances(availability_zones, networks)
        @job.state = safe_property(@job_spec, "state", class: String, optional: true)
        job_size = safe_property(@job_spec, "instances", class: Integer)
        instance_states = safe_property(@job_spec, "instance_states", class: Hash, default: {})

        networks.each do |network|
          static_ips = network.static_ips
          if static_ips && static_ips.size != job_size
            raise JobNetworkInstanceIpMismatch,
              "Job `#{@job.name}' has #{job_size} instances but was allocated #{static_ips.size} static IPs"
          end
        end

        instance_states.each_pair do |index_or_id, state|
          unless Job::VALID_JOB_STATES.include?(state)
            raise JobInvalidInstanceState,
              "Invalid state `#{state}' for `#{@job.name}/#{index_or_id}', valid states are: #{Job::VALID_JOB_STATES.join(", ")}"
          end

          @job.instance_states[index_or_id] = state
        end

        if @job.state && !Job::VALID_JOB_STATES.include?(@job.state)
          raise JobInvalidJobState,
            "Invalid state `#{@job.state}' for `#{@job.name}', valid states are: #{Job::VALID_JOB_STATES.join(", ")}"
        end

        job_size.times.map { DesiredInstance.new(@job, @deployment) }
      end

      def parse_migrated_from
        migrated_from = safe_property(@job_spec, 'migrated_from', class: Array, optional: true, :default => [])
        migrated_from.each do |migrated_from_job_spec|
          name = safe_property(migrated_from_job_spec, 'name', class: String)
          az = safe_property(migrated_from_job_spec, 'az', class: String, optional: true)
          unless az.nil?
            unless @job.availability_zones.to_a.map(&:name).include?(az)
              raise DeploymentInvalidMigratedFromJob,
              "Job '#{name}' specified for migration to job '#{@job.name}' refers to availability zone '#{az}'. " +
                "Az '#{az}' is not in the list of availability zones of job '#{@job.name}'."
            end
          end
          @job.migrated_from << MigratedFromJob.new(name, az)
        end
      end

      def validate_templates
        template_property = safe_property(@job_spec, 'template', optional: true)
        templates_property = safe_property(@job_spec, 'templates', optional: true)

        if template_property && templates_property
          raise JobInvalidTemplates,
                "Job `#{@job.name}' specifies both template and templates keys, only one is allowed"
        end

        if [template_property, templates_property].compact.empty?
          raise ValidationMissingField,
                "Job `#{@job.name}' does not specify template or templates keys, one is required"
        end
      end

      def assign_default_networks(networks)
        Network::VALID_DEFAULTS.each do |property|
          network = networks.find { |network| network.default_for?(property) }
          @job.default_network[property] = network.name if network
        end
      end
    end
  end
end
