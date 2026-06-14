# frozen_string_literal: true

require "test_helper"

class FrameworkState::FrameworkTest < ActiveSupport::TestCase
  context "#draft?" do
    should "be true when a draft is in progress" do
      framework = build(:framework_state, draft_in_progress: true)
      assert_predicate framework, :draft?
    end

    should "be false when no draft is in progress" do
      framework = build(:framework_state, draft_in_progress: false)
      assert_not framework.draft?
    end
  end
end
