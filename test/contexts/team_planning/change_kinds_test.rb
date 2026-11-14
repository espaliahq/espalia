# frozen_string_literal: true

require "test_helper"

class TeamPlanning::ChangeKindsTest < ActiveSupport::TestCase
  should "list every kind of change the plan's events define, each complete" do
    defined = Rails.root.glob("app/contexts/team_planning/events/*.rb")
      .map { "TeamPlanning::Events::#{it.basename(".rb").to_s.camelize}".constantize }
      .select { it < TeamPlanning::Events::Change }

    assert_equal defined.map(&:name).sort, TeamPlanning::ChangeKinds::ALL.sort
    assert TeamPlanning::ChangeKinds.all.all?(&:complete?)
  end

  should "find the kind that holds a facet, and refuse one no kind holds" do
    assert_equal TeamPlanning::Events::RuleSet, TeamPlanning::ChangeKinds.holding("rule:test_cap")
    assert_equal "No kind of change holds rule", assert_raises(TeamPlanning::Error) { TeamPlanning::ChangeKinds.holding("rule") }.message
  end
end
