# frozen_string_literal: true

# What the two exploration dialogs share (ADR-22): the lens params the
# controller returns to, the optional note, and the Cancel / submit row with
# the one-request guard.
module Views::Assessments::ExplorationModalForm
  private

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
        render Components::Kit::Button.new(variant: :outline, size: :sm,
                                           data: { action: "click->modal#close" }) { "Cancel" }
        render Components::Kit::Button.new(size: :sm, type: :submit,
                                           data: { turbo_submits_with: submitting }) { submit }
      end
    end
  end

  def note_field
    field_id = "#{self.class::ID}-note"
    div do
      label(for: field_id, class: "block text-sm font-medium text-muted") do
        plain "Note "
        span(class: "font-normal text-muted") { "(optional)" }
      end
      textarea(id: field_id, name: "note", rows: 3, maxlength: 1000,
               class: "mt-1 #{Components::Kit::Field::TEXTAREA}")
    end
  end

  def bullets(*lines)
    ul(class: "list-disc pl-5 space-y-1 text-sm text-muted") do
      lines.each { |line| li { line } }
    end
  end
end
