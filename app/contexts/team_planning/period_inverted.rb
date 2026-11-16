# frozen_string_literal: true

# A date edit, or the undo or redo of one, that would leave a scenario ending
# before it starts. The aggregate holds no names, so it carries the scenario's
# id for the caller to name it.
class TeamPlanning::PeriodInverted < TeamPlanning::Error
  attr_reader :scenario_id, :period

  # @param scenario_id [String] the scenario that would end before it starts
  # @param period [Range<Date>] the period it would have
  # @param moved [Boolean] whether it is the step being edited, not one after it
  def initialize(scenario_id:, period:, moved:)
    @scenario_id, @period = scenario_id, period
    super(message_for(moved ? "This scenario" : "A scenario after it"))
  end

  # @param name [String] what to call the scenario
  # @return [String] the refusal, naming it
  def message_for(name) = "#{name} would end on #{period.end.iso8601}, before it starts on #{period.begin.iso8601}"
end
