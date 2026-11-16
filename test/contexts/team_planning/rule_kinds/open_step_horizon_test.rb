# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::OpenStepHorizonTest < ActiveSupport::TestCase
  def check(value) = TeamPlanning::RuleKinds.check("open_step_horizon", value)

  def refusal(value) = assert_raises(TeamPlanning::Error) { check(value) }.message

  should "default to twelve months, set for the whole plan" do
    assert_equal 12, TeamPlanning::RuleKinds::OpenStepHorizon.months(TeamPlanning::RuleKinds.defaults.fetch("open_step_horizon"))
    assert TeamPlanning::RuleKinds::OpenStepHorizon.plan_wide?
  end

  should "keep whole months from 1 to 36" do
    assert_equal({ "months" => "1" }, check({ months: " 01 " }))
    assert_equal({ "months" => "36" }, check({ months: 36 }))
  end

  should "refuse months out of range or not whole, and any other key" do
    [ "0", "37", "1.5", "a year", "" ].each do |months|
      assert_equal "months must be whole months from 1 to 36, such as 18", refusal({ months: })
    end
    assert_equal "An open_step_horizon rule takes only months, not days", refusal({ months: "12", days: "3" })
  end
end
