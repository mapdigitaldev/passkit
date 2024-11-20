require 'apnotic'

module Passkit
  class Notification
    def self.trigger_for_generators(generators)
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
            response = connection.push(notification)
            responses_headers[pass_key][device_key] = response.headers
          rescue StandardError => e
            responses_headers[pass_key][device_key] = { error: e.message }
          end
        end
      end

      connection.close

      Rails.logger.info("triggered apple notifications: #{responses_headers.inspect}")

      responses_headers
    end
  end
end