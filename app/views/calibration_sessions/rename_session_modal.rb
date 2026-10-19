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
              class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Name" }
        input(
          id: "rename-session-name", type: "text", name: "calibration_session[name]",
          required: true, autocomplete: "off",
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
          data: { rename_session_form_target: "name" }
        )
      end
      div(class: "flex items-center gap-3") do
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm font-semibold " \
                 "text-white hover:bg-primary/90 transition-colors"
        ) { "Save" }
        button(
          type: "button", data: { action: "click->modal#close" },
          class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white"
        ) { "Cancel" }
      end
    end
  end
end
