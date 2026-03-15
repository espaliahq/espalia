# frozen_string_literal: true

require "test_helper"

class FrameworkState::BehaviouralExpectationTest < ActiveSupport::TestCase
  subject { build(:framework_behavioural_expectation) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:expectation_id)
    should validate_presence_of(:stable_id)
    should validate_presence_of(:capability_id)
    should validate_presence_of(:level_ordinal)
    should validate_presence_of(:description)
  end
end
