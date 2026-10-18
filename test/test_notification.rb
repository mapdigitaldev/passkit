# frozen_string_literal: true

require "rails_helper"
require "minitest/mock"

class TestNotification < ActiveSupport::TestCase
  # Answers each push from answers[token]; tokens without an answer stay unanswered.
  class FakeConnection
    attr_reader :pushed_tokens, :push_attempts, :closed

    def initialize(answers: {}, push_error: nil, join_error: nil, thread_error: nil)
      @answers = answers
      @push_error = push_error
      @join_error = join_error
      @thread_error = thread_error
      @pushed_tokens = []
      @push_attempts = 0
      @closed = false
    end

    def on(event, &block)
      @error_handler = block if event == :error
    end

    def prepare_push(notification)
      FakePush.new(notification.token)
    end

    def push_async(push)
      @push_attempts += 1
      raise @push_error if @push_error.is_a?(Exception)
      raise @push_error[push.token] if @push_error.is_a?(Hash) && @push_error[push.token]

      @pushed_tokens << push.token
      answer = @answers[push.token]
      push.respond(Apnotic::Response.new(headers: {":status" => answer[0]}, body: answer[1])) if answer
    end

    def join(timeout:)
      raise @join_error if @join_error

      @error_handler&.call(@thread_error) if @thread_error
    end

    def close
      @closed = true
    end
  end

  class FakePush
    attr_reader :token

    def initialize(token)
      @token = token
    end

    def on(event, &block)
      @on_response = block if event == :response
    end

    def respond(response)
      @on_response.call(response)
    end
  end

  setup do
    @log = StringIO.new
    @logger = Rails.logger
    Rails.logger = Logger.new(@log)
  end

  teardown do
    Rails.logger = @logger
  end

  def test_logs_an_accepted_update_once_per_pass_at_info
    pass = pass_with_devices("token-aaaaaa", "token-bbbbbb")
    connection = FakeConnection.new(answers: {"token-aaaaaa" => ["200", ""], "token-bbbbbb" => ["200", ""]})

    trigger(connection, pass.generator)

    assert_includes @log.string, "INFO -- : Passkit APNs pass update pass=#{pass.id} serial=#{pass.serial_number} devices=2 accepted=2\n"
    assert_includes @log.string, "Passkit APNs pass update passes=1 without_devices=0"
    assert_equal 1, @log.string.scan("pass=#{pass.id} ").size
    assert connection.closed
  end

  def test_logs_a_rejected_push_with_its_token_suffix_status_and_reason_at_error
    pass = pass_with_devices("token-aaaaaa", "token-bbbbbb")
    connection = FakeConnection.new(answers: {"token-aaaaaa" => ["200", ""], "token-bbbbbb" => ["410", '{"reason":"Unregistered"}']})

    trigger(connection, pass.generator)

    assert_includes @log.string, "ERROR -- : Passkit APNs pass update pass=#{pass.id} serial=#{pass.serial_number} devices=2 accepted=1 failed=…bbbbbb:410:Unregistered\n"
    refute_includes @log.string, "token-bbbbbb"
  end

  def test_logs_a_push_left_unanswered_when_the_wait_times_out
    pass = pass_with_devices("token-aaaaaa")
    connection = FakeConnection.new(join_error: NetHttp2::AsyncRequestTimeout)

    trigger(connection, pass.generator)

    assert_match(/ERROR -- : Passkit APNs pass update pass=#{pass.id} .*accepted=0 failed=…aaaaaa:no response error=NetHttp2::AsyncRequestTimeout: no answer within 60s/, @log.string)
    assert connection.closed
  end

  def test_closes_the_connection_when_waiting_fails_unexpectedly
    pass = pass_with_devices("token-aaaaaa")
    connection = FakeConnection.new(join_error: RuntimeError.new("boom"))

    assert_raises(RuntimeError) { trigger(connection, pass.generator) }
    assert connection.closed
  end

  def test_stops_at_a_connection_failure_and_names_the_passes_it_could_not_reach
    first = pass_with_devices("token-aaaaaa")
    second = pass_with_devices("token-bbbbbb")
    connection = FakeConnection.new(push_error: Errno::ECONNREFUSED.new)

    trigger(connection, [first.generator, second.generator])

    assert_equal 1, connection.push_attempts
    assert_includes @log.string, "ERROR -- : Passkit APNs pass update not sent passes=#{first.id},#{second.id} error=Errno::ECONNREFUSED: Connection refused\n"
    assert connection.closed
  end

  def test_records_a_push_that_fails_on_its_own_and_carries_on
    pass = pass_with_devices("token-aaaaaa", "token-bbbbbb")
    connection = FakeConnection.new(answers: {"token-bbbbbb" => ["200", ""]},
      push_error: {"token-aaaaaa" => ArgumentError.new("bad token")})

    trigger(connection, pass.generator)

    assert_equal ["token-bbbbbb"], connection.pushed_tokens
    assert_includes @log.string, "accepted=1 failed=…aaaaaa:ArgumentError: bad token\n"
  end

  def test_logs_an_error_raised_on_the_connection_thread
    pass = pass_with_devices("token-aaaaaa")
    connection = FakeConnection.new(thread_error: SocketError.new("Socket was remotely closed"))

    trigger(connection, pass.generator)

    assert_includes @log.string, "failed=…aaaaaa:no response error=SocketError: Socket was remotely closed"
  end

  def test_logs_a_pass_cut_off_by_a_connection_failure_and_the_passes_after_it
    cut_off = pass_with_devices("token-aaaaaa", "token-bbbbbb")
    after = pass_with_devices("token-cccccc")
    connection = FakeConnection.new(answers: {"token-aaaaaa" => ["200", ""]},
      push_error: {"token-bbbbbb" => Errno::ECONNREFUSED.new})

    trigger(connection, [cut_off.generator, after.generator])

    assert_includes @log.string, "ERROR -- : Passkit APNs pass update pass=#{cut_off.id} serial=#{cut_off.serial_number} devices=2 accepted=1 error=Errno::ECONNREFUSED: Connection refused\n"
    assert_includes @log.string, "not sent passes=#{after.id} error=Errno::ECONNREFUSED"
  end

  def test_logs_a_push_closed_without_a_status
    pass = pass_with_devices("token-aaaaaa")
    connection = FakeConnection.new(answers: {"token-aaaaaa" => [nil, ""]})

    trigger(connection, pass.generator)

    assert_includes @log.string, "failed=…aaaaaa:closed without status\n"
  end

  def test_logs_what_was_sent_when_sending_is_interrupted
    first = pass_with_devices("token-aaaaaa")
    second = pass_with_devices("token-bbbbbb")
    connection = FakeConnection.new(answers: {"token-aaaaaa" => ["200", ""]})
    second.define_singleton_method(:touch) { raise ActiveRecord::StatementInvalid, "deadlock" }

    Passkit::Pass.stub(:where, ->(*) { FakeRelation.new([first, second]) }) do
      assert_raises(ActiveRecord::StatementInvalid) { trigger(connection, nil) }
    end

    assert_includes @log.string, "INFO -- : Passkit APNs pass update pass=#{first.id} "
    assert_includes @log.string, "ERROR -- : Passkit APNs pass update not sent passes=#{second.id}\n"
  end

  def test_counts_passes_without_registered_devices
    with_device = pass_with_devices("token-aaaaaa")
    without_device = pass_with_devices
    connection = FakeConnection.new(answers: {"token-aaaaaa" => ["200", ""]})

    trigger(connection, [with_device.generator, without_device.generator])

    assert_includes @log.string, "Passkit APNs pass update passes=2 without_devices=1"
    refute_includes @log.string, "pass=#{without_device.id} "
  end

  private

  FakeRelation = Struct.new(:passes) do
    def includes(*) = self
    def to_a = passes
  end

  def trigger(connection, generators)
    Apnotic::Connection.stub(:new, connection) do
      Passkit::Notification.async_trigger_for_generators(generators)
    end
  end

  def pass_with_devices(*tokens)
    pass = Passkit::Pass.create!(klass: "Passkit::ExampleStoreCard", generator: User.create!(name: "Ada"))
    tokens.each_with_index do |token, index|
      device = Passkit::Device.create!(identifier: "#{pass.id}-device-#{index}", push_token: token)
      pass.registrations.create!(device: device)
    end
    pass
  end
end
