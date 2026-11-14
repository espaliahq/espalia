# frozen_string_literal: true

require "test_helper"

class TeamPlanning::ChangeKindsTest < ActiveSupport::TestCase
  should "hold every kind of change the plan's events define, and nothing a test defines" do
    defined = Rails.root.glob("app/contexts/team_planning/events/*.rb")
      .map { "TeamPlanning::Events::#{it.basename(".rb").to_s.camelize}".constantize }
      .select { it < TeamPlanning::Events::Change }

    assert_includes defined, TeamPlanning::Events::RuleSet
    assert_equal defined.sort_by(&:name), TeamPlanning::ChangeKinds.all
  end

  should "make every kind clearable and pinnable: complete, with a facet only it holds" do
    TeamPlanning::ChangeKinds.all.each do |kind|
      assert kind.complete?, "#{kind} names a facet and says how it lands on a map"
      others = TeamPlanning::ChangeKinds.all - [ kind ]
      assert others.none? { it.holds?(kind.facet) || kind.holds?(it.facet) }, "#{kind} shares a facet with another kind"
    end
  end

  should "subscribe the overrides projection to every kind" do
    assert_empty TeamPlanning::ChangeKinds.all - TeamPlanning::Projections::Overrides.handled_events
  end

  should "find the kind that holds a facet, and refuse one no kind holds" do
    assert_equal TeamPlanning::Events::RuleSet, TeamPlanning::ChangeKinds.holding("rule:test_cap")
    assert_equal "No kind of change holds rule", assert_raises(TeamPlanning::Error) { TeamPlanning::ChangeKinds.holding("rule") }.message
  end
end
