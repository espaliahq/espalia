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

    should "accept nil deficit_threshold (inherits framework default)" do
      subject.deficit_threshold = nil
      assert subject.valid?
    end

    should "accept zero deficit_threshold (must balance)" do
      subject.deficit_threshold = 0
      assert subject.valid?
    end

    should "accept positive deficit_threshold" do
      subject.deficit_threshold = 3.0
      assert subject.valid?
    end

    should "reject negative deficit_threshold" do
      subject.deficit_threshold = -0.5
      assert_not subject.valid?
      assert_includes subject.errors[:deficit_threshold], "must be greater than or equal to 0"
    end
  end
end
