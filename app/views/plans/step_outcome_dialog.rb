# frozen_string_literal: true

# A closed step's plan beside what happened
# ([#466](https://github.com/espaliahq/espalia/issues/466)), opened from the
# step's badge on the Scenarios table or the timeline. Its body is a lazy
# frame, so the Org Graph is read only once someone opens it.
class Views::Plans::StepOutcomeDialog < Views::Base
  # @param scenario_id [String]
  # @return [String] the dialog's DOM id
  def self.id_for(scenario_id) = "step-outcome-#{scenario_id}"

  # @param scenario_id [String]
  # @return [Hash] the data a trigger carries to open the dialog
  def self.trigger(scenario_id) = { action: "click->modal#open", modal_target_id: id_for(scenario_id) }

  # @param scenario [Hash] from `team_planning_scenarios`
  # @return [Boolean] whether it has an outcome to show
  def self.offered?(scenario) = scenario[:state] == "closed"

  # @param plan_id [String]
  # @param scenario [Hash] from `team_planning_scenarios`
  def initialize(plan_id:, scenario:)
    @plan_id = plan_id
    @scenario = scenario
  end

  def view_template
    render Components::Kit::Modal.new(id: self.class.id_for(@scenario[:scenario_id]), title: "#{@scenario[:name]}: planned against actual",
                                      size: :"3xl", standalone: false, panel_data: { controller: "frame-error" }) do |m|
      m.body do
        render Views::Plans::StepOutcome.new(scenario_id: @scenario[:scenario_id],
                                             src: plan_scenario_outcome_path(@plan_id, @scenario[:scenario_id]))
        render Components::Shared::FrameLoadError.new(id: "#{self.class.id_for(@scenario[:scenario_id])}-error", subject: "the outcome",
                                                      closeable: true, classes: "space-y-3")
      end
    end
  end
end
