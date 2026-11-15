# frozen_string_literal: true

# The plan page's Covers dialog, where an editor changes which units the plan
# covers ([#338](https://github.com/espaliahq/espalia/issues/338)). It sits
# under the page's own `modal` controller.
class Views::Plans::ScopeDialog < Views::Base
  ID = "plan-scope-dialog"

  # @return [Hash] the data a button carries to open the dialog
  def self.trigger = { action: "click->modal#open", modal_target_id: ID }

  # @param plan [Hash] from `team_planning_plan`
  # @param units [Array<Hash>] from `team_planning_coverable_units`
  def initialize(plan:, units:)
    @plan = plan
    @units = units
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "What this plan covers", size: :lg, standalone: false,
                                      dirty_guard: "Discard your changes?") do |m|
      m.body { scope_form }
    end
  end

  private

  def scope_form
    form(action: scope_plan_path(@plan[:plan_id]), method: "post", class: "space-y-4") do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      render Views::Plans::ScopeFields.new(id: "plan-scope-change", units: @units, chosen: @plan[:scope][:units],
                                           hint: "Widen it whenever you like. It narrows only while nothing planned falls outside.")
      div(class: "flex items-center gap-3") do
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save" }
        render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
      end
    end
  end
end
