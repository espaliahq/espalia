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
  # What the assumption adds to one step of a scenario. A kind leaves out
  # anyone {TeamPlanning::Forecast::Frame#covered?} names, as a planned change
  # already says what happens to them.
  #
  # @param frame [TeamPlanning::Forecast::Frame]
  # @return [Array<TeamPlanning::Forecast::Row>]
  def self.forecast(frame) = raise(NotImplementedError, "#{name} must say what it forecasts")
end
