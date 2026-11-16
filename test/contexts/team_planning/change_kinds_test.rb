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

  should "make every kind clearable and pinnable: complete" do
    TeamPlanning::ChangeKinds.all.each { assert it.complete?, "#{it} names a facet and says how it lands on a map" }
  end

  should "subscribe the overrides projection to every kind" do
    assert_empty TeamPlanning::ChangeKinds.all - TeamPlanning::Projections::Overrides.handled_events
  end

  # Status compares whole end states and never knows who is reading, so a kind
  # that holds pay stays untracked until Status strips money for a member
  # without see-pay ([#446](https://github.com/espaliahq/espalia/issues/446)).
  should "keep every change that holds pay out of Status" do
    Operations::TeamPlanning::ChangeNote.hidden_facets(see_pay: false).each do |facet|
      TeamPlanning::ChangeKinds.holding(facet).each do |kind|
        change = kind.new(data: { subject_id: SecureRandom.uuid_v7, field: facet.split(":", 2).last })
        assert_not kind.tracks?(change), "#{kind} holds #{facet}: strip its money in TeamPlanning::Status for a member without see-pay first"
      end
    end
  end

  should "find every kind that holds a facet, and refuse one no kind holds" do
    assert_equal [ TeamPlanning::Events::RuleSet ], TeamPlanning::ChangeKinds.holding("rule:test_cap")
    assert_equal [ TeamPlanning::Events::PositionClosed, TeamPlanning::Events::PositionSet ], TeamPlanning::ChangeKinds.holding("position")
    assert_equal "No kind of change holds rule", assert_raises(TeamPlanning::Error) { TeamPlanning::ChangeKinds.holding("rule") }.message
  end
end
