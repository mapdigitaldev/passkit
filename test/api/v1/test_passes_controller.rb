# frozen_string_literal: true

require "rails_helper"

class TestPassesController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  ENCRYPTION_KEY = "0123456789abcdef"

  setup do
    @routes = Passkit::Engine.routes
    @original_encryption_key = ENV["PASSKIT_URL_ENCRYPTION_KEY"]
    ENV["PASSKIT_URL_ENCRYPTION_KEY"] = ENCRYPTION_KEY
  end

  teardown do
    ENV["PASSKIT_URL_ENCRYPTION_KEY"] = @original_encryption_key
  end

  def test_create
    payload = Passkit::PayloadGenerator.encrypted(Passkit::ExampleStoreCard)
    get passes_api_path(payload)
    assert_equal 1, Passkit::Pass.count
    assert_response :success
    zip_file = Zip::File.open_buffer(StringIO.new(response.body))
    assert_equal 7, zip_file.size
  end

  def test_create_collection
    payload = Passkit::PayloadGenerator.encrypted(Passkit::UserTicket, User.find(1), :tickets)
    get passes_api_path(payload)
    assert_response :success
    assert_equal 2, Passkit::Pass.count
    unzipped_passes = Zip::File.open_buffer(StringIO.new(response.body))
    assert_equal 2, unzipped_passes.size # the main zip file contains two passes
    unzipped_pass =  Zip::File.open_buffer(unzipped_passes.first.zipfile)
    assert_includes unzipped_passes.first.name, '.pkpass'
  end

  def test_show
    _pkpass = Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    assert_equal 1, Passkit::Pass.count
    pass = Passkit::Pass.last
    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number)
    assert_response :unauthorized

    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}

    assert_response :success

    get pass_path(pass_type_id: ENV["PASSKIT_PASS_TYPE_IDENTIFIER"], serial_number: pass.serial_number),
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}", "If-Modified-Since" => Time.zone.now.httpdate}

    assert_equal "", response.body
    assert_equal pass.last_update.httpdate, response.headers["Last-Modified"]
    assert_response :not_modified
  end

  def test_create_rejects_a_truncated_payload
    assert_payload_rejected issued_payload[0..-3], OpenSSL::Cipher::CipherError
  end

  def test_create_rejects_an_extended_payload
    assert_payload_rejected "#{issued_payload}AB", OpenSSL::Cipher::CipherError
  end

  def test_create_rejects_a_payload_encrypted_with_another_key
    payload = encrypt_plaintext('{"valid_until":"2099-01-01T00:00:00Z"}', key: "fedcba9876543210")
    assert_payload_rejected payload, OpenSSL::Cipher::CipherError
  end

  def test_create_rejects_a_payload_with_tampered_ciphertext
    payload = issued_payload
    first_block_hex_length = 32
    payload[0, first_block_hex_length] = "0" * first_block_hex_length
    assert_payload_rejected payload, JSON::ParserError
  end

  def test_create_rejects_a_payload_whose_field_names_are_not_utf8
    payload = encrypt_plaintext("{\"valid_until\":\"2099-01-01T00:00:00Z\",\"\xFF\":1}".b)
    assert_payload_rejected payload, EncodingError
  end

  def test_create_rejects_a_payload_whose_expiry_is_not_utf8
    payload = encrypt_plaintext("{\"valid_until\":\"\xFF\"}".b)
    assert_payload_rejected payload, ArgumentError
  end

  def test_create_answers_an_expired_payload_with_not_found
    payload = Passkit::UrlEncrypt.encrypt(valid_until: 1.day.ago)
    log = capture_log { get passes_api_path(payload) }
    assert_response :not_found
    refute_includes log, "Passkit pass payload rejected"
  end

  private

  def issued_payload
    Passkit::PayloadGenerator.encrypted(Passkit::ExampleStoreCard)
  end

  def encrypt_plaintext(plaintext, key: ENCRYPTION_KEY)
    cipher = OpenSSL::Cipher.new("AES-128-CBC").encrypt
    cipher.key = key
    (cipher.update(plaintext) + cipher.final).unpack1("H*").upcase
  end

  def assert_payload_rejected(payload, error_class)
    log = capture_log { get passes_api_path(payload) }
    assert_response :not_found
    assert_includes log, "Passkit pass payload rejected: #{error_class} (#{payload.length} characters)"
  end

  def capture_log
    output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    yield
    output.string
  ensure
    Rails.logger = original_logger
  end
end
