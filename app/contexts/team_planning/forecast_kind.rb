# frozen_string_literal: true

# A forecast assumption, such as an attrition rate. It is a rule like any
# other, so it takes a tenant default, resolves down the scenario chain and
# can be set for one unit through team_planning_set_rule. It also says what it
# adds to a scenario: rows from {.forecast}, which {TeamPlanning::Forecast}
# computes when read and never stores (decision 5).
#
# @example
#   class TeamPlanning::RuleKinds::Attrition < TeamPlanning::ForecastKind
#     def self.rule_name = "attrition"
#     def self.forecast(frame) = frame.map.units.map { frame.row(unit_id: it.id, headcount: -1r) }
#   end
class TeamPlanning::ForecastKind < TeamPlanning::RuleKind
  # What the assumption adds to one step of a scenario. A kind decides which
  # planned changes already say what happens to someone:
  # {TeamPlanning::Forecast::Frame#covered?} names every subject a change sets,
  # and attrition drops only planned leavers, as a pay or level change keeps a
  # seat filled. A row's run_rate is what its headcount, still changed on the
  # step's last day, costs a year, so the scenario's run rate at its end
  # carries it.
  #
  # @param frame [TeamPlanning::Forecast::Frame]
  # @return [Array<TeamPlanning::Forecast::Row>]
  def self.forecast(frame) = raise(NotImplementedError, "#{name} must say what it forecasts")

  # How many days past its step's end the assumption can still add to later
  # steps, from every value its rules could take there, so a later step reads
  # only the earlier steps that could reach it.
  #
  # @param values [Hash{String => Array<Hash>}] rule name => each value it could take
  # @return [Integer, nil] nil when nothing carries past the step
  def self.reach(values) = nil
end
