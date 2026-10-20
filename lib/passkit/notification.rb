require "apnotic"

module Passkit
  class Notification
    JOIN_TIMEOUT = 60
    # Failures of the connection itself: every later push on it would fail the same way.
    CONNECTION_ERRORS = [SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError].freeze

    def self.async_trigger_for_generators(generators)
      passes = Passkit::Pass.where(generator: generators).includes(:devices).to_a
      return {} if passes.empty?

      new(passes).trigger
    end

    def initialize(passes)
      @passes = passes
      @results = {}
      @results_lock = Mutex.new
      @connection_error = nil
    end

    def trigger
      connection = Apnotic::Connection.new(cert_path: Rails.root.join(Passkit.configuration.private_p12_certificate),
        cert_pass: Passkit.configuration.certificate_key)
      # Socket errors arrive on the connection's own thread; without a handler they re-raise in this process.
      connection.on(:error) { |error| @connection_error ||= error }

      attempted = []
      begin
        send_pushes(connection, attempted)
        join(connection)
      ensure
        connection.close
        log_results(attempted)
      end
    end

    private

    # Fills `attempted` with [pass, device, apns_id], stopping at the first connection failure.
    def send_pushes(connection, attempted)
      @passes.each do |pass|
        pass.touch # update the updated_at field to mark it as changed

        pass.devices.each do |device|
          notification = Apnotic::Notification.new(device.push_token)
          notification.alert = {} # empty json as required in apple docs
          notification.topic = Passkit.configuration.pass_type_identifier

          apns_id = notification.apns_id
          attempted << [pass, device, apns_id]
          push = connection.prepare_push(notification)
          push.on(:response) { |response| record(apns_id, response) }
          connection.push_async(push)
        rescue *CONNECTION_ERRORS => e
          @connection_error ||= e
          attempted.pop
          return attempted
        rescue => e
          record_failure(apns_id, e)
        end
      end
    end

    def join(connection)
      connection.join(timeout: JOIN_TIMEOUT)
    rescue NetHttp2::AsyncRequestTimeout
      @connection_error ||= NetHttp2::AsyncRequestTimeout.new("no answer within #{JOIN_TIMEOUT}s")
    end

    # Runs on the connection's thread.
    def record(apns_id, response)
      body = response.body
      @results_lock.synchronize do
        @results[apns_id] = {status: response.status, reason: (body["reason"] if body.is_a?(Hash))}
      end
    end

    def record_failure(apns_id, error)
      @results_lock.synchronize { @results[apns_id] = {status: nil, reason: error_summary(error)} }
    end

    def log_results(attempted)
      attempted.group_by(&:first).each do |pass, pushes|
        log_pass(pass, pushes)
      end

      unreached = @passes.reject { |pass| pass.devices.empty? } - attempted.map(&:first).uniq
      if unreached.any?
        line = "Passkit APNs pass update not sent passes=#{unreached.map(&:id).join(",")}"
        line += " error=#{error_summary(@connection_error)}" if @connection_error
        Rails.logger.error(line)
      end

      Rails.logger.info("Passkit APNs pass update passes=#{@passes.size} without_devices=#{@passes.count { |pass| pass.devices.empty? }}")
    end

    def log_pass(pass, pushes)
      accepted = pushes.count { |(_, _, apns_id)| @results.dig(apns_id, :status) == "200" }
      line = "Passkit APNs pass update pass=#{pass.id} serial=#{pass.serial_number} devices=#{pass.devices.size} accepted=#{accepted}"

      if accepted == pass.devices.size
        Rails.logger.info(line)
        return
      end

      failures = pushes.filter_map do |(_, device, apns_id)|
        result = @results[apns_id]
        next if result&.dig(:status) == "200"

        "…#{device.push_token.to_s.last(6)}:#{outcome(result)}"
      end
      line += " failed=#{failures.join(",")}" if failures.any?
      line += " error=#{error_summary(@connection_error)}" if @connection_error
      Rails.logger.error(line)
    end

    def outcome(result)
      return "no response" unless result
      return result[:reason] || "closed without status" unless result[:status]

      [result[:status], result[:reason]].compact.join(":")
    end

    def error_summary(error)
      "#{error.class}: #{error.message}"
    end
  end
end
