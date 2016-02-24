require 'json'
require 'httpclient'
require 'base64'

module Bosh::Cli
  module Client
    module Http

      DIRECTOR_HTTP_ERROR_CODES = [400, 401, 403, 404, 500]
      API_TIMEOUT     = 86400 * 3
      CONNECT_TIMEOUT = 30

      attr_reader :num_retries, :retry_wait_interval


      def post(uri, content_type = nil, payload = nil, headers = {}, options = {})
        request(:post, uri, content_type, payload, headers, options)
      end

      def put(uri, content_type = nil, payload = nil, headers = {}, options = {})
        request(:put, uri, content_type, payload, headers, options)
      end

      def get(uri, content_type = nil, payload = nil, headers = {}, options = {})
        request(:get, uri, content_type, payload, headers, options)
      end

      def delete(uri, content_type = nil, payload = nil, headers = {}, options = {})
        request(:delete, uri, content_type, payload, headers, options)
      end

    private

      def director_name
        raise CliExit, "you need to implement '#{__method__}' for class #{self}"
      end

      def request(method, uri, content_type = nil, payload = nil, headers = {}, options = {})
        headers = headers.dup
        headers['Content-Type'] = content_type if content_type
        headers['Host'] = @director_uri.host

        tmp_file = nil
        response_reader = nil
        if options[:file]
          tmp_file = File.open(File.join(Dir.mktmpdir, 'streamed-response'), 'w')
          response_reader = lambda { |part| tmp_file.write(part) }
        end

        response = try_to_perform_http_request(
          method,
          "#{@scheme}://#{@director_ip}:#{@port}#{uri}",
          payload,
          headers,
          num_retries,
          retry_wait_interval,
          &response_reader
        )

        if options[:file]
          tmp_file.close
          body = tmp_file.path
        else
          body = response.body
        end

        if DIRECTOR_HTTP_ERROR_CODES.include?(response.code)
          if response.code == 404
            raise ResourceNotFound, parse_error_message(response.code, body, uri)
          else
            raise DirectorError, parse_error_message(response.code, body, uri)
          end
        end

        headers = response.headers.inject({}) do |hash, (k, v)|
          # Some HTTP clients symbolize headers, some do not.
          # To make it easier to switch between them, we try
          # to symbolize them ourselves.
          hash[k.to_s.downcase.gsub(/-/, '_').to_sym] = v
          hash
        end

        [response.code, body, headers]

      rescue SystemCallError => e
        raise DirectorError, "System call error while talking to director: #{e}"
      end

      def parse_error_message(status, body, uri)
        parsed_body = JSON.parse(body.to_s) rescue {}

        if parsed_body['code'] && parsed_body['description']
          'Error %s: %s' % [parsed_body['code'],
                            parsed_body['description']]
        elsif status == 404
          "The #{director_name} bosh director doesn't understand the following API call: #{uri}." +
            " The bosh deployment may need to be upgraded."
        else
          'HTTP %s: %s' % [status, body]
        end
      end

      def try_to_perform_http_request(method, uri, payload, headers, num_retries, retry_wait_interval, &response_reader)
        num_retries.downto(1) do |n|
          begin
            return perform_http_request(method, uri, payload, headers, &response_reader)

          rescue DirectorInaccessible
            warning("cannot access director, trying #{n-1} more times...") if n != 1
            raise if n == 1
            sleep(retry_wait_interval)
          end
        end
      end

      def generate_http_client
        @http_client ||= HTTPClient.new.tap do |http_client|
          http_client.send_timeout    = API_TIMEOUT
          http_client.receive_timeout = API_TIMEOUT
          http_client.connect_timeout = CONNECT_TIMEOUT
        end
      end

      def perform_http_request(method, uri, payload = nil, headers = {}, &block)
        http_client = generate_http_client

        if @ca_cert.nil?
          http_client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http_client.ssl_config.verify_callback = Proc.new {}
        else
          unless File.exists?(@ca_cert)
            err('Invalid ca certificate path')
          end

          parsed_url = nil
          begin
            parsed_url = URI.parse(uri)
          rescue => e
            err("Failed to parse director URL: #{e.message}")
          end

          unless parsed_url.instance_of?(URI::HTTPS)
            err('CA certificate cannot be used with HTTP protocol')
          end

          # pass in client certificate
          begin
            cert_store = OpenSSL::X509::Store.new
            cert_store.add_file(@ca_cert)
          rescue OpenSSL::X509::StoreError => e
            err("Invalid SSL Cert for '#{uri}': #{e.message}")
          end
          http_client.ssl_config.cert_store = cert_store
        end

        if @credentials
          headers['Authorization'] = @credentials.authorization_header
        end

        http_client.request(method, uri, {
          :body => payload,
          :header => headers,
        }, &block)

      rescue URI::Error,
             SocketError,
             Errno::ECONNREFUSED,
             Errno::ETIMEDOUT,
             Errno::ECONNRESET,
             Timeout::Error,
             HTTPClient::TimeoutError,
             HTTPClient::KeepAliveDisconnected,
             OpenSSL::SSL::SSLError,
             OpenSSL::X509::StoreError => e

        if e.is_a?(OpenSSL::SSL::SSLError) && e.message.include?('certificate verify failed')
          err("Invalid SSL Cert for '#{uri}': #{e.message}")
        end
        raise DirectorInaccessible, "cannot access director (#{e.message})"

      rescue HTTPClient::BadResponseError => e
        err("Received bad HTTP response from director: #{e}")

      # HTTPClient doesn't have a root exception but instead subclasses RuntimeError
      rescue RuntimeError => e
        say("Perform request #{method}, #{uri}, #{headers.inspect}, #{payload.inspect}")
        err("REST API call exception: #{e}")
      end

      def get_json(url)
        status, body = get_json_with_status(url)
        raise AuthError if status == 401
        raise DirectorError, "Director HTTP #{status}" if status != 200
        body
      end

      def get_json_with_status(url)
        status, body, _ = get(url, 'application/json')
        body = JSON.parse(body) if status == 200
        [status, body]
      rescue JSON::ParserError
        raise DirectorError, "Cannot parse director response: #{body}"
      end

      def add_query_string(url, parts)
        if parts.size > 0
          "#{url}?#{URI.encode_www_form(parts)}"
        else
          url
        end
      end
    end
  end
end
