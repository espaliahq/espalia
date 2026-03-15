# frozen_string_literal: true

require "test_helper"

class FrameworkState::FrameworkTest < ActiveSupport::TestCase
  subject { build(:framework_state) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:framework_id)
    should validate_presence_of(:name)
  end
end
