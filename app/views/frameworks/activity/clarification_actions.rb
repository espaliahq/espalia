# frozen_string_literal: true

# The actionable affordance for a pending clarification — a single "Resolve…"
# button opening the root-mounted resolve modal (the resolution note is
# required input, so there is no one-click path; §12's needs-input rule).
# Shared by the feed entry and the pane's suggestion card so the modal's
# dataset contract can't drift between surfaces.
#
class Views::Frameworks::Activity::ClarificationActions < Views::Base
  # @param framework_id [String]
  # @param suggestion_id [String]
  # @param question_preview [String, nil] the clarification's question, shown in the modal
  def initialize(framework_id:, suggestion_id:, question_preview: nil)
    @framework_id = framework_id
    @suggestion_id = suggestion_id
    @question_preview = question_preview
  end

  def view_template
    div(class: "mt-1.5 flex items-center gap-2") do
      button(
        type: "button",
        class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
               "bg-primary text-white hover:bg-primary/80 transition-colors",
        data: {
          action: "click->modal#open",
          modal_target_id: "resolve-clarification-modal",
          resolve_clarification_id: @suggestion_id,
          resolve_question_preview: @question_preview
        }
      ) { "Resolve…" }
    end
  end
end
