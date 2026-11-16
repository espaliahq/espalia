# frozen_string_literal: true

# Confirms closing a step once its period has ended, or reopening the last one
# closed ([#466](https://github.com/espaliahq/espalia/issues/466)). Closing says
# what it does to the steps after it, so nobody closes one to tidy the list.
class Views::Plans::StepClosureDialog < Views::Base
  SETTLED = %w[closed not_taken].freeze

  # @param scenario_id [String]
  # @return [String] the dialog's DOM id
  def self.id_for(scenario_id) = "step-closure-#{scenario_id}"

  # @param scenario_id [String]
  # @return [Hash] the data a trigger carries to open the dialog
  def self.trigger(scenario_id) = { action: "click->modal#open", modal_target_id: id_for(scenario_id) }

  # @param scenario [Hash] from `team_planning_scenarios`
  # @return [Boolean] whether it is closed or wasn't taken, so only a rename changes it
  def self.settled?(scenario) = SETTLED.include?(scenario[:state])

  # The steps an editor can close now, and the last one closed, which is the
  # only one that can reopen.
  #
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @return [Array<Array(Hash, Symbol)>] each scenario with :close or :reopen
  def self.offered(scenarios)
    last_closed = scenarios.select { it[:state] == "closed" }.max_by { it[:ends_on] }
    scenarios.select { it[:state] == "ready_to_close" }.map { [ it, :close ] } + (last_closed ? [ [ last_closed, :reopen ] ] : [])
  end

  # @param plan_id [String]
  # @param scenario [Hash] from `team_planning_scenarios`
  # @param mode [Symbol] :close or :reopen
  # @param scenarios [Array<Hash>] the plan's scenarios, to name the alternatives closing leaves not taken
  # @param return_to [String, nil] the timeline to land back on
  def initialize(plan_id:, scenario:, mode:, scenarios:, return_to: nil)
    @plan_id = plan_id
    @scenario = scenario
    @mode = mode
    @scenarios = scenarios
    @return_to = return_to
  end

  # @return [String]
  def scenario_id = @scenario[:scenario_id]

  # @return [Symbol] :close or :reopen
  attr_reader :mode

  def view_template
    title = @mode == :close ? "Close #{@scenario[:name]}?" : "Reopen #{@scenario[:name]}?"
    render Components::Kit::Modal.new(id: self.class.id_for(@scenario[:scenario_id]), title:, size: :md, standalone: false) do |m|
      m.body do
        div(class: "space-y-3 text-sm text-default") { @mode == :close ? closing : reopening }
        form(action: plan_scenario_closure_path(@plan_id, @scenario[:scenario_id]), method: "post", class: "mt-6 flex flex-wrap items-center gap-3") do
          input(type: "hidden", name: "_method", value: "delete") if @mode == :reopen
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          input(type: "hidden", name: "return_to", value: @return_to) if @return_to
          render Components::Kit::Button.new(type: :submit) { @mode == :close ? "Close step" : "Reopen step" }
          render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
        end
      end
    end
  end

  private

  def closing
    p { "This step ended on #{Views::Plans::ScenarioTable.day(@scenario[:ends_on])}." }
    p do
      "The steps after it will start from the organisation as the Org Graph holds it on #{Views::Plans::ScenarioTable.day(day_after)}. " \
        "Anything this step planned that hasn't happened by then carries over to them."
    end
    p { "While it is closed, only its name and description can change." }
    p(data: { not_taken: "" }) { "#{not_taken.to_sentence} will read Not taken." } if not_taken.any?
    p { "You can reopen it while no later step is closed." }
  end

  def reopening
    p { "The steps after it will stand on the plan's own base again, as before it closed." }
    p { "It can be changed again." }
  end

  def day_after = (Date.iso8601(@scenario[:ends_on]) + 1).iso8601

  # Alternatives to this step, or to the steps it replaces, that closing it passes over.
  def not_taken
    @not_taken ||= begin
      chain = []
      current = @scenario
      while current && instead?(current)
        current = @scenarios.find { it[:scenario_id] == current[:parent_id] }
        chain << current if current
      end
      ids = (chain + [ @scenario ]).to_set { it[:scenario_id] }
      rivals = @scenarios.select { instead?(it) && ids.include?(it[:parent_id]) }
      passed = (chain + rivals).reject { it[:scenario_id] == @scenario[:scenario_id] }
      (passed + passed.flat_map { following(it) }).uniq.reject { SETTLED.include?(it[:state]) }.map { it[:name] }
    end
  end

  # The steps after a passed-over scenario, and their alternatives, which close
  # with it. The step being closed and the steps after it stay open.
  def following(row)
    children = @scenarios.select { it[:parent_id] == row[:scenario_id] && it[:scenario_id] != @scenario[:scenario_id] }
    children.flat_map { [ it, *following(it) ] }
  end

  def instead?(row)
    case row[:relation]
    in "instead" then true
    in "then" | "on" | nil then false
    end
  end
end
