# frozen_string_literal: true

# What the two exploration dialogs share (ADR-22): the lens params the
# controller returns to, the optional note, and the Cancel / submit row with
# the one-request guard.
module Views::Assessments::ExplorationModalForm
  private

  BUTTON = "text-sm font-medium px-3 py-1.5 rounded-md cursor-pointer focus-visible:outline-hidden " \
           "focus-visible:ring-2 focus-visible:ring-primary"

  # @param action [String]
  # @yield the fields above the note
  def exploration_form(action:, submit:, submitting:, &fields)
    form(action: action, method: "post", class: "space-y-4",
         data: { controller: "submit-guard",
                 action: "submit->submit-guard#guard turbo:submit-start->submit-guard#start " \
                         "turbo:submit-end->submit-guard#end" }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      @lens.to_params.each { |name, value| input(type: "hidden", name: name.to_s, value: value) }
      fields.call
      note_field
      div(class: "flex justify-end gap-2 pt-1") do
        button(type: "button", data: { action: "click->modal#close" },
               class: "#{BUTTON} border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 " \
                      "hover:bg-gray-50 dark:hover:bg-gray-800") { "Cancel" }
        button(type: "submit", data: { turbo_submits_with: submitting },
               class: "#{BUTTON} font-semibold bg-gray-900 dark:bg-white text-white dark:text-gray-900 " \
                      "hover:bg-gray-800 dark:hover:bg-gray-100") { submit }
      end
    end
  end

  def note_field
    field_id = "#{self.class::ID}-note"
    div do
      label(for: field_id, class: "block text-sm font-medium text-gray-700 dark:text-gray-200") do
        plain "Note "
        span(class: "font-normal text-gray-500 dark:text-gray-400") { "(optional)" }
      end
      textarea(id: field_id, name: "note", rows: 3, maxlength: 1000,
               class: "mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white " \
                      "dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                      "focus:outline-hidden focus:ring-2 focus:ring-primary")
    end
  end

  def bullets(*lines)
    ul(class: "list-disc pl-5 space-y-1 text-sm text-gray-700 dark:text-gray-200") do
      lines.each { |line| li { line } }
    end
  end
end
