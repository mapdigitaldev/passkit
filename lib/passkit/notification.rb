require 'apnotic'

module Passkit
  class Notification
    def self.async_trigger_for_generators(generators)
      passes = Passkit::Pass.where(generator: generators)
      return {} if passes.empty?

      connection = Apnotic::Connection.new(cert_path: Rails.root.join(Passkit.configuration.private_p12_certificate),
                                           cert_pass: Passkit.configuration.certificate_key)

      responses_headers = {}
      passes.each do |pass|
        pass_key = "pass_#{pass.id}"
        responses_headers[pass_key] = {}

        pass.touch # update the updated_at field to mark it as changed

        pass.devices.each do |device|
          device_key = "device_#{device.id}"
          notification = Apnotic::Notification.new(device.push_token)
          notification.alert = {} # empty json as required in apple docs
          notification.topic = Passkit.configuration.pass_type_identifier

          begin
            # prepare push
            push = connection.prepare_push(notification)
            push.on(:response) { |response| Rails.logger.info("triggered apple notifications: #{response.headers.inspect}") }
            push.on(:error) { |exception| Rails.logger.error("triggered apple notifications error: #{exception}") }

            # send
            connection.push_async(push)
          rescue StandardError => e
            Rails.logger.error("triggered apple notifications push failure: #{e}")
          end
        end
      end

      # wait for all requests to be completed
      connection.join(timeout: 60)

      # close the connection
      connection.close
    end
  end
end