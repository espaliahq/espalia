# frozen_string_literal: true

require "test_helper"

class FrameworkState::CapabilityTest < ActiveSupport::TestCase
  subject { build(:framework_capability) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:category_id)
    should validate_presence_of(:capability_id)
    should validate_presence_of(:stable_id)
    should validate_presence_of(:name)
    should validate_presence_of(:status)
    should validate_inclusion_of(:status).in_array(%w[active archived])
  end

  context "scopes" do
    should "return active capabilities" do
      tenant = create(:tenant)

      ActsAsTenant.with_tenant(tenant) do
        active = create(:framework_capability, status: "active")
        archived = create(:framework_capability, status: "archived")

        assert_includes FrameworkState::Capability.active, active
        assert_not_includes FrameworkState::Capability.active, archived
      end
    end
  end
end
