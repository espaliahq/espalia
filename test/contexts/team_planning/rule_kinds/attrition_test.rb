# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::AttritionTest < ActiveSupport::TestCase
  def check(rule, value) = TeamPlanning::RuleKinds.check(rule, value)

  def refusal(rule, value) = assert_raises(TeamPlanning::Error) { check(rule, value) }.message

  should "forecast nothing by default, and keep a backfill out for 90 days" do
    defaults = TeamPlanning::RuleKinds.defaults
    assert_equal 0r, TeamPlanning::RuleKinds::Attrition.yearly_rate(defaults.fetch("attrition"))
    assert_equal 90, TeamPlanning::RuleKinds::TimeToHire.days(defaults.fetch("time_to_hire"))
    assert_includes TeamPlanning::RuleKinds.forecasts, TeamPlanning::RuleKinds::Attrition
    assert_not_includes TeamPlanning::RuleKinds.forecasts, TeamPlanning::RuleKinds::TimeToHire
  end

  should "keep a rate from 0 to 1 as typed" do
    [ "0", "0.12", "1", "1.0", "0.0525" ].each { assert_equal({ "yearly_rate" => it }, check("attrition", { yearly_rate: " #{it} " })) }
  end

  should "refuse a rate outside 0 to 1, or too fine, and any other key" do
    [ "-0.1", "1.2", "12%", "0.12345", "" ].each do |rate|
      assert_equal "yearly_rate must be a share of a year from 0 to 1, such as 0.12", refusal("attrition", { yearly_rate: rate })
    end
    assert_equal "An attrition rule takes only yearly_rate, not unit", refusal("attrition", { yearly_rate: "0.1", unit: "year" })
  end

  should "keep whole days to hire up to two years, and refuse anything else" do
    assert_equal({ "days" => "60" }, check("time_to_hire", { days: "060" }))
    assert_equal({ "days" => "0" }, check("time_to_hire", { days: 0 }))
    [ "731", "-1", "6.5", "soon" ].each do |days|
      assert_equal "days must be whole days from 0 to 730, such as 60", refusal("time_to_hire", { days: })
    end
    assert_equal "A time_to_hire rule takes only days, not weeks", refusal("time_to_hire", { days: "60", weeks: "8" })
  end
end
