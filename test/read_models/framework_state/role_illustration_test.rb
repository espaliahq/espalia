# frozen_string_literal: true

require "test_helper"

class FrameworkState::RoleIllustrationTest < ActiveSupport::TestCase
  subject { build(:framework_role_illustration) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:illustration_id)
    should validate_presence_of(:stable_id)
    should validate_presence_of(:expectation_id)
    should validate_presence_of(:role_id)
    should validate_presence_of(:ordinal)
    should validate_presence_of(:description)
  end
end
