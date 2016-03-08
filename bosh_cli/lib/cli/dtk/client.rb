require 'cli/client/http'
require 'cli/dtk/stream/element'

module Bosh::Cli
  module Dtk
    class Client

      include ::Bosh::Cli::Client::Http

      def initialize(dtk_info, options = {})
        unless dtk_info
          raise DirectorMissing, 'no dtk info provided'
        end

        @director_uri        = URI.parse(dtk_info['host'])
        @director_ip         = Resolv.getaddresses(@director_uri.host).last
        @scheme              = @director_uri.scheme
        @port                = @director_uri.port
        @credentials         = ::Bosh::Cli::Client::BasicCredentials.new(dtk_info['username'], dtk_info['password'])
        @track_tasks         = !options.delete(:no_track)
        @num_retries         = options.fetch(:num_retries, 5) || 5
        @retry_wait_interval = options.fetch(:retry_wait_interval, 5) || 5
        @ca_cert             = options[:ca_cert]
        @service_module      = dtk_info['service_module'] || {}
        @assembly_template   = dtk_info['assembly_template'] || {}
      end

      def stage(deployment_name, target_cpi)
        service_module_name    = required('service_module.name', @service_module['name'])
        service_module_ns      = required('service_module.namespace', @service_module['namespace'])
        service_module_version = @service_module['version']
        assembly_name          = required('assembly_template.name', @assembly_template['name'])

        # TODO: compute these rather than being constants
        os_type = 'trusty'

        payload = {
          :name => deployment_name,
          :target_id => target_cpi,
          :name => instance_name,
          :silent_fail => true,
          :assembly_id => assembly_name,
          :service_module_name => "#{service_module_ns}:#{service_module_name}",
        }

        # ability to bypass version
        payload.merge!(:version => service_module_version) unless service_module_version.nil?
        # os_type optional
        payload.merge!(:os_type => os_type) unless 'none'.eql?(os_type)

        result = handle_response  { post('/rest/assembly/stage', nil, payload) }
        service_obj = YAML.load(result)["new_service_instance"]
        [service_obj["id"], service_obj["name"], service_obj["is_created"]]
      end

      def exec_sync(assembly_id)
        payload = {
          :assembly_id => assembly_id,
          :task_action => "create",
          :task_params => nil
        }
        result = handle_response  { post('/rest/assembly/exec', nil, payload) }

        task_listen(assembly_id)
      end

      def task_listen(assembly_id)
        index = 0
        next_step = nil

        while true
          elements = task_status(assembly_id, index, next_step)
          elements.each do |el|
            el.render
            if el.is_increment?
              index += 1
            end
            # only if it changes we assign it
            next_step = el.next_step ? el.next_step : next_step
            return if el.is_finished?
          end

          sleep(5)
        end
      end

      def task_status(assembly_id, index, next_step = nil)
        payload = {
            :assembly_id => assembly_id,
                   :form => :stream_form,
            :start_index => index,
              :end_index => index
        }

        payload.merge!( :wait_for => next_step) if next_step
        response = handle_response  { post('/rest/assembly/task_status', nil, payload) }

        # we transform each
        response.collect { |el| Element.new(el) }
      end

      def director_name
        'DTK'
      end

    private

      def handle_response(&block)
        status_code, response, _ = yield
        res_hash = JSON.parse(response)
        unless res_hash["status"] == "ok"
          error_msg = res_hash["errors"].collect { |err_obj| err_obj["message"] }.join(', ')
          raise CliExit, "DTK Error, #{error_msg}"
        end
        res_hash["data"]
      end

      def required(param_name, param)
        raise CliExit, "dtk param '#{param_name}' is missing in bosh config file" if param.nil?
        param
      end
    end
  end
end
