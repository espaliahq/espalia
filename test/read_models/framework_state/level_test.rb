# frozen_string_literal: true

require "test_helper"

class FrameworkState::LevelTest < ActiveSupport::TestCase
  subject { build(:framework_level) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:role_id)
    should validate_presence_of(:level_id)
    should validate_presence_of(:ordinal)
    should validate_presence_of(:title)
    should validate_presence_of(:code)
  end
end
