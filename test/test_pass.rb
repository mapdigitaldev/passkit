# frozen_string_literal: true

require "rails_helper"

class TestPass < ActiveSupport::TestCase
  def test_last_update_is_the_later_of_the_generator_and_the_pass
    user = User.create!(name: "Ada")
    pass = Passkit::Pass.create!(klass: "Passkit::UserStoreCard", generator: user)
    user.update_columns(updated_at: 2.days.ago)

    pass.update_columns(updated_at: 1.hour.ago)
    assert_in_delta 1.hour.ago, Passkit::Pass.find(pass.id).last_update, 1

    user.update_columns(updated_at: 1.minute.ago)
    assert_in_delta 1.minute.ago, Passkit::Pass.find(pass.id).last_update, 1
  end
end
