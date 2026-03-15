# frozen_string_literal: true

require "test_helper"

class FrameworkState::RoleTest < ActiveSupport::TestCase
  subject { build(:framework_role) }

  context "associations" do
    should belong_to(:tenant)
  end

  context "validations" do
    should validate_presence_of(:role_family_id)
    should validate_presence_of(:role_id)
    should validate_presence_of(:name)
    should validate_presence_of(:code)
    should validate_presence_of(:track)
    should validate_inclusion_of(:track).in_array(%w[ic management])
  end
end
