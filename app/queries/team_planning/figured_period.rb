# frozen_string_literal: true

# The days a scenario's figures run over. A step with an end runs to it. A
# step with no end date runs for the plan's `open_step_horizon` rule, in whole
# months from its start: to the day before the same date, or to the month's
# last day when it has no such date. Cost, budget, funding and the forecast
# stay finite while the step itself stays open.
#
# @!attribute period [Range<Date>] always with an end
# @!attribute open_ended [Boolean] whether the step has no end date
# @!attribute horizon_months [Integer, nil] the months shown, for an open step
TeamPlanning::FiguredPeriod = Data.define(:period, :open_ended, :horizon_months) do
  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param scenario_id [String]
  # @param map [TeamPlanning::Baseline::Map] the scenario's resolved map, which holds its rules
  # @return [TeamPlanning::FiguredPeriod, nil] nil for an id with no period, such as the plan's
  def self.for(aggregate, scenario_id, map)
    period = aggregate.period_of(scenario_id) or return nil
    return new(period:, open_ended: false, horizon_months: nil) if period.end

    months = TeamPlanning::RuleKinds::OpenStepHorizon.months(map.rule(TeamPlanning::RuleKinds::OpenStepHorizon.rule_name))
    following = period.begin >> months
    new(period: period.begin..(following.day == period.begin.day ? following - 1 : following), open_ended: true, horizon_months: months)
  end

  # @return [Hash] `{ open_ended:, horizon_months: }`, as an Operation's payload adds them
  def payload = { open_ended:, horizon_months: }
end
