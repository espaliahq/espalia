# frozen_string_literal: true

# Shared reject-suggestion modal for the Framework Explorer (edit mode). One
# instance per page; each actionable feed entry's "Reject" button opens it,
# passing the suggestion id / entity label / proposed-value preview via the
# trigger dataset (read by the `reject-suggestion-form` Stimulus controller,
# which also points the form at that suggestion's reject endpoint).
#
# Rejecting always routes here (never inline) so a reviewer can add an optional
# reason — surfaced back in the activity feed. Submits to
# {Frameworks::SuggestionsController#reject}, which responds head :ok to the
# Turbo submit; the modal closes, the feed reloads off the activity broadcast,
# and the grid refreshes via the `suggestion:resolved` event.
class Views::Frameworks::Explorer::RejectSuggestionModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "reject-suggestion-modal", title: "Reject suggestion", standalone: false
    ) do |m|
      m.body { reject_form }
    end
  end

  private

  def reject_form
    form(
      # __SID__ is substituted with the suggestion id by reject-suggestion-form
      # when the modal opens (the id varies per trigger).
      action: reject_framework_suggestion_path(@framework_id, "__SID__"),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "reject-suggestion-form",
        reject_suggestion_form_action_template_value: reject_framework_suggestion_path(@framework_id, "__SID__"),
        action: "turbo:submit-end->modal#submitted turbo:submit-end->reject-suggestion-form#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      # Marks this as an inline submit so the controller returns 204 (Turbo
      # closes the modal via submit-end) instead of redirecting to the index.
      input(type: "hidden", name: "inline", value: "1")

      p(class: "text-sm text-muted") do
        plain "Reject the proposed change to "
        span(class: "font-semibold text-default",
             data: { reject_suggestion_form_target: "title" }) { "this suggestion" }
        plain "."
      end

      p(class: "hidden rounded-md bg-subtle px-3 py-2 text-sm " \
               "text-muted line-clamp-3",
        data: { reject_suggestion_form_target: "preview" })

      reason_field
      actions
    end
  end

  def reason_field
    div do
      label(for: "reject_reason",
            class: "block text-sm font-medium text-default mb-1") do
        plain "Reason "
        span(class: "font-normal text-muted") { "(optional)" }
      end
      textarea(
        id: "reject_reason", aria: { describedby: "reject_reason-hint" }, name: "comment", rows: "2",
        class: Components::Kit::Field::TEXTAREA, placeholder: "Why is this being rejected?",
        data: { reject_suggestion_form_target: "reason" }
      )
      p(id: "reject_reason-hint", class: "mt-1 text-xs text-muted") { Prose::COMPOSER_HINT }
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      render Components::Kit::Button.new(tone: :danger, type: :submit) { "Reject suggestion" }
      render Components::Kit::Button.new(variant: :ghost, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end
end
