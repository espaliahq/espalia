# frozen_string_literal: true

# The calibration list's shared "Rename session" dialog — one per page,
# opened from each card's kebab, which passes the session's rename URL and
# current name through the trigger dataset (read by the `rename-session-form`
# controller). Closed and archived sessions have no reason to be opened just
# to rename them. Submits to {CalibrationSessions::NamesController#update},
# which redirects back here.
class Views::CalibrationSessions::RenameSessionModal < Views::Base
  ID = "rename-session-modal"

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Rename session", size: :sm, standalone: false) do |m|
      m.body { rename_form }
    end
  end

  private

  def rename_form
    form(
      method: "post",
      class: "space-y-4",
      data: { controller: "rename-session-form", action: "turbo:submit-end->modal#submitted" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch")
      div do
        label(for: "rename-session-name",
              class: "block text-sm font-medium text-default mb-1") { "Name" }
        input(
          id: "rename-session-name", type: "text", name: "calibration_session[name]",
          # Whitespace-only is refused here too, so the server's refusal —
          # a redirect that closes the dialog — is left for a real race.
          required: true, pattern: ".*\\S.*", title: "The name can’t be blank", autocomplete: "off",
          class: Components::Kit::Field::INPUT,
          data: { rename_session_form_target: "name" }
        )
      end
      div(class: "flex items-center gap-3") do
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save" }
        render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
      end
    end
  end
end
