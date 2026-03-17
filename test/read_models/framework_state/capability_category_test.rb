# frozen_string_literal: true

require "test_helper"

class FrameworkState::CapabilityCategoryTest < ActiveSupport::TestCase
  subject { build(:framework_capability_category) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:framework_id)
    should validate_presence_of(:category_id)
    should validate_presence_of(:name)

    should "accept nil category_tolerance (uncapped)" do
      subject.category_tolerance = nil
      assert subject.valid?
    end

    should "accept zero category_tolerance (must balance)" do
      subject.category_tolerance = 0
      assert subject.valid?
    end

    should "accept positive category_tolerance" do
      subject.category_tolerance = 3.0
      assert subject.valid?
    end

    should "reject negative category_tolerance" do
      subject.category_tolerance = -0.5
      assert_not subject.valid?
      assert_includes subject.errors[:category_tolerance], "must be greater than or equal to 0"
    end
  end
end
