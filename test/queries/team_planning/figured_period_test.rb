# frozen_string_literal: true

require "test_helper"

class TeamPlanning::FiguredPeriodTest < ActiveSupport::TestCase
  Rules = Data.define(:months) do
    def rule(name) = name == "open_step_horizon" ? { "months" => months.to_s } : raise(KeyError, name)
  end

  setup do
    @plan_id = SecureRandom.uuid_v7
    @editor_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @editor_id)
  end

  def fork(parent_id = @plan_id, relation: "then", ends_on: nil, starts_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: "S", ends_on:, starts_on:, forked_by_id: @editor_id)
    end
  end

  should "run a step with an end to its end, whatever the horizon" do
    q1 = fork(ends_on: "2027-03-31")
    figured = TeamPlanning::FiguredPeriod.for(@plan, q1, Rules.new(6))

    assert_equal Date.new(2027, 1, 1)..Date.new(2027, 3, 31), figured.period
    assert_equal({ open_ended: false, horizon_months: nil }, figured.payload)
  end

  should "run a step with no end date over whole months from its start, as an alternative sharing it does" do
    q1 = fork(starts_on: "2027-04-01")
    lean = fork(q1, relation: "instead")

    assert_equal Date.new(2027, 4, 1)..Date.new(2028, 3, 31), TeamPlanning::FiguredPeriod.for(@plan, q1, Rules.new(12)).period
    assert_equal Date.new(2027, 4, 1)..Date.new(2027, 9, 30), TeamPlanning::FiguredPeriod.for(@plan, lean, Rules.new(6)).period
    assert_equal({ open_ended: true, horizon_months: 18 }, TeamPlanning::FiguredPeriod.for(@plan, q1, Rules.new(18)).payload)
  end

  should "end a start the next month lacks on that month's last day" do
    q1 = fork(starts_on: "2027-01-31")
    assert_equal Date.new(2027, 1, 31)..Date.new(2027, 2, 28), TeamPlanning::FiguredPeriod.for(@plan, q1, Rules.new(1)).period
  end

  should "have no period for the plan itself" do
    assert_nil TeamPlanning::FiguredPeriod.for(@plan, @plan_id, Rules.new(12))
  end
end
