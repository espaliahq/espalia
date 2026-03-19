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

    should "accept nil deficit_threshold" do
      subject.deficit_threshold = nil
      assert subject.valid?
    end

    should "accept zero deficit_threshold (no deficit allowed)" do
      subject.deficit_threshold = 0
      assert subject.valid?
    end

    should "accept positive deficit_threshold" do
      subject.deficit_threshold = 2.5
      assert subject.valid?
    end

    should "reject negative deficit_threshold" do
      subject.deficit_threshold = -1
      assert_not subject.valid?
      assert_includes subject.errors[:deficit_threshold], "must be greater than or equal to 0"
    end

    should "accept nil overperformance_cap" do
      subject.overperformance_cap = nil
      assert subject.valid?
    end

    should "accept zero overperformance_cap" do
      subject.overperformance_cap = 0
      assert subject.valid?
    end

    should "reject negative overperformance_cap" do
      subject.overperformance_cap = -1
      assert_not subject.valid?
      assert_includes subject.errors[:overperformance_cap], "must be greater than or equal to 0"
    end
  end
end
