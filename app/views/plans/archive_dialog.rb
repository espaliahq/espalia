# frozen_string_literal: true

# The plan page's Archive dialog, where an editor sets a plan aside without
# deleting it ([#383](https://github.com/espaliahq/espalia/issues/383)). It
# sits under the page's own `modal` controller.
class Views::Plans::ArchiveDialog < Views::Base
  ID = "plan-archive-dialog"

  # @return [Hash] the data a button carries to open the dialog
  def self.trigger = { action: "click->modal#open", modal_target_id: ID }

  # @param plan_id [String]
  def initialize(plan_id:)
    @plan_id = plan_id
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Archive this plan?", size: :md, standalone: false) do |m|
      m.body do
        div(class: "space-y-3 text-sm text-default") do
          p { "An archived plan keeps everything in it, but nobody can change it and it stops being checked against the organisation." }
          p { "Its members can still read it, and any editor can restore it later." }
        end
        form(action: archive_plan_path(@plan_id), method: "post", class: "mt-6 flex items-center gap-3") do
          input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
          render Components::Kit::Button.new(tone: :brand, type: :submit) { "Archive plan" }
          render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
        end
      end
    end
  end
end
