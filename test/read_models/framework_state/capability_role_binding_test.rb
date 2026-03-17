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

    should "accept nil individual_tolerance" do
      subject.individual_tolerance = nil
      assert subject.valid?
    end

    should "accept zero individual_tolerance (mandatory)" do
      subject.individual_tolerance = 0
      assert subject.valid?
    end

    should "accept positive individual_tolerance" do
      subject.individual_tolerance = 2.5
      assert subject.valid?
    end

    should "reject negative individual_tolerance" do
      subject.individual_tolerance = -1
      assert_not subject.valid?
      assert_includes subject.errors[:individual_tolerance], "must be greater than or equal to 0"
    end
  end

  context "#mandatory?" do
    should "return true when individual_tolerance is zero" do
      subject.individual_tolerance = 0
      assert subject.mandatory?
    end

    should "return false when individual_tolerance is nil" do
      subject.individual_tolerance = nil
      assert_not subject.mandatory?
    end

    should "return false when individual_tolerance is positive" do
      subject.individual_tolerance = 1.5
      assert_not subject.mandatory?
    end
  end
end
