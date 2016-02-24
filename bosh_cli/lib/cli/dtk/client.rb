require 'cli/client/http'
require 'cli/dtk/stream/element'

module Bosh::Cli
  module Dtk
    class Client

      include ::Bosh::Cli::Client::Http

      def initialize(dtk_credentials, options = {})
        unless dtk_credentials
          raise DirectorMissing, 'no dtk info provided'
        end

        @director_uri        = URI.parse(dtk_credentials['host'])
        @director_ip         = Resolv.getaddresses(@director_uri.host).last
        @scheme              = @director_uri.scheme
        @port                = @director_uri.port
        @credentials         = ::Bosh::Cli::Client::BasicCredentials.new(dtk_credentials['username'], dtk_credentials['password'])
        @track_tasks         = !options.delete(:no_track)
        @num_retries         = options.fetch(:num_retries, 5) || 5
        @retry_wait_interval = options.fetch(:retry_wait_interval, 5) || 5
        @ca_cert             = options[:ca_cert]
      end

      def list_components
        ap "List componetns on DTK"
        ap post('/rest/component_module/list', 'application/json', {})
        # ap get_json('/rest/component_module/list')
      end

      def stage(deployment_name, target_cpi)
        service_module_name, assembly_name, instance_name = extract_dtk_essential_from_name(deployment_name)

        payload = {
          :assembly_id => assembly_name,
          :service_module_name => service_module_name,
          :target_id => target_cpi,
          :name => instance_name
        }

        result = handle_response  { post('/rest/assembly/stage', nil, payload) }
        service_obj = YAML.load(result)["new_service_instance"]
        [service_obj["id"], service_obj["name"]]
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

        while true
          # ap "CALL GOES #{assembly_id} #{index}"
          elements = task_status(assembly_id, index)
          # ap elements

          elements.each do |el|
            el.render
            if el.is_increment?
              index += 1
            end
            return if el.is_finished?
          end

          sleep(5)
        end
      end

      def task_status(assembly_id, index)
        payload = {
            :assembly_id => assembly_id,
                   :form => :stream_form,
            :start_index => index,
              :end_index => index
        }

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

      def extract_dtk_essential_from_name(deployment_name)
        arr = deployment_name.split('-')
        raise CliExit, "deployment name not dtk valid '#{deployment_name}'" unless (arr.size == 3)
        [arr[0], arr[1], "#{arr[1]}-#{arr[2]}"]
      end

    end
  end
end