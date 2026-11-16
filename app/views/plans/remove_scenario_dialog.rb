# frozen_string_literal: true

# Confirms removing one scenario ([#439](https://github.com/espaliahq/espalia/issues/439)),
# opened from its row's menu or the map's header. It says how many changes go
# with it and that it can't be restored. An editor who can't see pay also reads
# {Operations::TeamPlanning::RemoveScenario.approval_notice}, which the caller
# passes in as the operation words it. A scenario others fork from can't be
# removed yet, so its dialog names them and offers no Remove.
class Views::Plans::RemoveScenarioDialog < Views::Base
  # @param scenario_id [String]
  # @return [String] the dialog's DOM id
  def self.id_for(scenario_id) = "remove-scenario-#{scenario_id}"

  # @param scenario_id [String]
  # @return [Hash] the data a trigger carries to open the dialog
  def self.trigger(scenario_id) = { action: "click->modal#open", modal_target_id: id_for(scenario_id) }

  # The scenarios that must go before this one can: any that fork from it.
  #
  # @param scenario [Hash] from `team_planning_scenarios`
  # @param scenarios [Array<Hash>] the plan's scenarios
  # @return [Array<String>] their names; empty when it can be removed
  def self.forks(scenario, scenarios) = scenarios.select { it[:parent_id] == scenario[:scenario_id] }.map { it[:name] }

  # @param plan_id [String]
  # @param scenario [Hash] from `team_planning_scenarios`
  # @param forks [Array<String>] from {.forks}
  # @param hidden_pay [String, nil] the operation's approval notice, for an editor who can't see pay
  def initialize(plan_id:, scenario:, forks:, hidden_pay: nil)
    @plan_id = plan_id
    @scenario = scenario
    @forks = forks
    @hidden_pay = hidden_pay
  end

  # @return [String]
  def scenario_id = @scenario[:scenario_id]

  def view_template
    title = @forks.any? ? "#{@scenario[:name]} can't be removed yet" : "Remove #{@scenario[:name]}?"
    render Components::Kit::Modal.new(id: self.class.id_for(@scenario[:scenario_id]), title:, size: :md, standalone: false) do |m|
      m.body { @forks.any? ? blocked : confirm }
    end
  end

  private

  def blocked
    count = @forks.size
    p(class: "text-sm text-default break-words") do
      plain "#{count} #{count == 1 ? 'scenario forks' : 'scenarios fork'} from it: #{@forks.to_sentence}. "
      plain "Remove #{count == 1 ? 'that' : 'those'} first."
    end
    div(class: "mt-6") do
      render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Close" }
    end
  end

  def confirm
    div(class: "space-y-3 text-sm text-default") do
      p { "#{held} It can't be restored, and it will be listed under Removed scenarios." }
      p(data: { hidden_pay: "" }) { @hidden_pay } if @hidden_pay
    end
    form(action: plan_scenario_path(@plan_id, @scenario[:scenario_id]), method: "post", class: "mt-6 flex flex-wrap items-center gap-3") do
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      render Components::Kit::Button.new(tone: :danger, type: :submit) { "Remove scenario" }
      render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end

  def held
    count = @scenario[:changes].to_i
    return "It holds no changes." if count.zero?

    "Its #{count} #{count == 1 ? 'change goes' : 'changes go'} with it."
  end
end
