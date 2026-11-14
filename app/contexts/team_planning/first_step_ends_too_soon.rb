# frozen_string_literal: true

# An update to a base after the first step ends. The aggregate holds no
# names, so it carries the step's id for the caller to name it.
class TeamPlanning::FirstStepEndsTooSoon < TeamPlanning::Error
  attr_reader :scenario_id, :ends_on, :base_on

  # @param scenario_id [String] the first step
  # @param ends_on [Date] the day it ends
  # @param base_on [Date] the base asked for
  def initialize(scenario_id:, ends_on:, base_on:)
    @scenario_id, @ends_on, @base_on = scenario_id, ends_on, base_on
    super(message_for("The first step"))
  end

  # @param name [String] what to call the step
  # @return [String] the refusal, naming the step
  def message_for(name) = "#{name} ends on #{ends_on.iso8601}, before #{base_on.iso8601}: end it later or remove it first"
end
