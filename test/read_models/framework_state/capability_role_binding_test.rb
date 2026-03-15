# frozen_string_literal: true

require "test_helper"

class FrameworkState::CapabilityRoleBindingTest < ActiveSupport::TestCase
  subject { build(:framework_capability_role_binding) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:binding_id)
    should validate_presence_of(:capability_id)
    should validate_presence_of(:role_id)
    should validate_presence_of(:weight)
    should validate_presence_of(:requirement_type)
    should validate_inclusion_of(:requirement_type).in_array(%w[must_have flexible])
  end
end
