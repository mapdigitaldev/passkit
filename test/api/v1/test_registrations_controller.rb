# frozen_string_literal: true

require "rails_helper"

class TestRegistrationsController < ActionDispatch::IntegrationTest
  include Passkit::Engine.routes.url_helpers

  DEVICE_ID = "device-library-identifier"

  setup do
    @routes = Passkit::Engine.routes
  end

  def test_create
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass1 = Passkit::Pass.first
    pass2 = Passkit::Pass.last

    assert_equal 2, Passkit::Pass.count

    register_pass(pass1)
    assert_equal 1, pass1.devices.count

    register_pass(pass2)
    assert_equal 1, pass2.devices.count
  end

  def test_show
  end

  def test_create_keeps_the_device_push_token_current_when_already_registered
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    register_pass(pass)

    register_pass(pass, push_token: "rotated-token")

    assert_response :ok
    assert_equal "rotated-token", Passkit::Device.find_by(identifier: DEVICE_ID).push_token
  end

  def test_create_keeps_the_push_token_when_the_registration_has_none
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    register_pass(pass)

    post device_register_path(device_id: DEVICE_ID, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: "",
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}

    assert_response :ok
    assert_equal "1234567890", Passkit::Device.find_by(identifier: DEVICE_ID).push_token
  end

  def test_create_keeps_the_device_push_token_current_for_another_pass
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    register_pass(Passkit::Pass.first)

    register_pass(Passkit::Pass.last, push_token: "rotated-token")

    assert_response :created
    assert_equal 1, Passkit::Device.count
    assert_equal "rotated-token", Passkit::Device.first.push_token
  end

  def test_destroy
    Passkit::Factory.create_pass(Passkit::ExampleStoreCard)
    pass = Passkit::Pass.first
    register_pass(pass)
    destroy_registration(pass.registrations.first)
    assert_equal 0, pass.devices.count
    assert_equal 0, Passkit::Registration.count
    assert_equal 1, Passkit::Pass.count
    assert_equal 1, Passkit::Device.count
  end

  private

  def register_pass(pass, push_token: "1234567890")
    post device_register_path(device_id: DEVICE_ID, pass_type_id: pass.pass_type_identifier, serial_number: pass.serial_number),
      params: {pushToken: push_token}.to_json,
      headers: {"Authorization" => "ApplePass #{pass.authentication_token}"}
  end

  def destroy_registration(registration)
    delete device_unregister_path(device_id: registration.device.identifier,
      pass_type_id: registration.pass.pass_type_identifier,
      serial_number: registration.pass.serial_number),
      params: {}.to_json,
      headers: {"Authorization" => "ApplePass #{registration.pass.authentication_token}"}
  end
end
