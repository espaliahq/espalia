# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::WorkingHoursTest < ActiveSupport::TestCase
  def check(value) = TeamPlanning::RuleKinds.check("working_hours", value)

  def refusal(value) = assert_raises(TeamPlanning::Error) { check(value) }.message

  should "default to 40 hours a week for 52 weeks" do
    assert_equal 2_080r, TeamPlanning::RuleKinds::WorkingHours.hours_per_year(TeamPlanning::RuleKinds.defaults.fetch("working_hours"))
  end

  should "keep the hours as typed, taking an exact number too" do
    assert_equal({ "hours_per_year" => "1950.5" }, check({ hours_per_year: " 1950.5 " }))
    assert_equal({ "hours_per_year" => "1950" }, check({ hours_per_year: 1950 }))
  end

  should "refuse hours that aren't a year's worth, and any other key" do
    [ "0", "-40", "8785", "lots", "1950.555" ].each do |hours|
      assert_equal "hours_per_year must be the hours in a full-time year, such as 1950", refusal({ hours_per_year: hours })
    end
    assert_equal "A working_hours rule takes only hours_per_year, not weeks", refusal({ hours_per_year: "1950", weeks: "52" })
  end
end
