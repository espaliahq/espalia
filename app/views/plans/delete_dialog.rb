# frozen_string_literal: true

# The plan page's Delete dialog ([#382](https://github.com/espaliahq/espalia/issues/382)).
# The editor types the plan's name to confirm, and a live plan offers
# archiving as the gentler choice. It sits under the page's own `modal` controller.
class Views::Plans::DeleteDialog < Views::Base
  ID = "plan-delete-dialog"

  # @return [Hash] the data a button carries to open the dialog
  def self.trigger = { action: "click->modal#open", modal_target_id: ID }

  # @param plan [Hash] from `team_planning_plan`
  def initialize(plan:)
    @plan = plan
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Delete this plan?", size: :md, standalone: false) do |m|
      m.body do
        div(class: "space-y-3 text-sm text-default") do
          p do
            plain "Deleting "
            strong(class: "break-words") { @plan[:name] }
            plain " removes its scenarios, notes and members for good. It can't be restored."
          end
          archive_instead unless @plan[:archived]
        end
        form(action: plan_path(@plan[:plan_id]), method: "post", class: "mt-6 space-y-4") do
          input(type: "hidden", name: "_method", value: "delete")
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          div do
            label(for: "plan_delete_name", class: "block text-sm font-medium text-default") { "Type the plan's name to confirm" }
            input(id: "plan_delete_name", name: "confirm_name", type: "text", required: true, autocomplete: "off",
                  spellcheck: "false", class: "mt-1 #{Components::Kit::Field::INPUT}")
          end
          div(class: "flex flex-wrap items-center gap-3") do
            render Components::Kit::Button.new(tone: :danger, type: :submit) { "Delete plan" }
            render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
          end
        end
      end
    end
  end

  private

  def archive_instead
    div(class: "rounded-md border border-default bg-subtle p-3") do
      p { "Want it out of the way but not gone? Archive it instead: it leaves the list of live plans, and any editor can restore it later." }
      form(action: archive_plan_path(@plan[:plan_id]), method: "post", class: "mt-3") do
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Archive instead" }
      end
    end
  end
end
