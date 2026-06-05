# frozen_string_literal: true

# Turbo Frame holding the manager-rating delegation add-form and the active
# delegation list. Lives inside the "Delegates" modal and is re-rendered by
# {Assessments::DelegationsController} on grant/revoke so the modal updates in
# place without closing.
#
class Views::Assessments::Delegations::Frame < Views::Base
  FRAME_ID = "delegations-list"

  # @param assignment [PersonFrameworkAssignment]
  # @param active_delegations [Array<ManagerAssessmentDelegation>]
  # @param candidate_delegates [Enumerable<Person>]
  # @param error [String, nil]
  def initialize(assignment:, active_delegations:, candidate_delegates:, error: nil)
    @assignment = assignment
    @active_delegations = active_delegations
    @candidate_delegates = candidate_delegates
    @error = error
  end

  def view_template
    turbo_frame_tag(FRAME_ID) do
      error_banner if @error.present?
      add_form
      active_list
    end
  end

  private

  def error_banner
    div(class: "mb-3 rounded-md bg-red-50 dark:bg-red-900/30 px-3 py-2 text-sm " \
               "text-red-700 dark:text-red-300") { @error }
  end

  def add_form
    form(action: assessment_delegations_path(@assignment), method: "post", class: "mb-4") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

      person_field
      expiry_field
      reason_field
      div(class: "mt-3 flex justify-end") do
        button(type: "submit",
               class: "px-3 py-1.5 text-sm rounded-md bg-primary text-white hover:bg-primary/90 cursor-pointer") do
          "Add delegate"
        end
      end
    end
  end

  def person_field
    div(class: "mb-3") do
      label(for: "delegation_delegate_person_id", class: label_classes) { "Delegate to" }
      select(id: "delegation_delegate_person_id", name: "delegation[delegate_person_id]",
             required: true, class: input_classes) do
        option(value: "") { "— Pick a person —" }
        @candidate_delegates.each do |person|
          option(value: person.id) { person.name.presence || person.email }
        end
      end
    end
  end

  def expiry_field
    div(class: "mb-3") do
      label(for: "delegation_expires_at", class: label_classes) { "Expires (optional)" }
      input(id: "delegation_expires_at", type: "date", name: "delegation[expires_at]",
            class: input_classes)
    end
  end

  def reason_field
    div(class: "mb-1") do
      label(for: "delegation_reason", class: label_classes) { "Reason (optional)" }
      input(id: "delegation_reason", type: "text", name: "delegation[reason]",
            maxlength: 200, placeholder: "e.g. seconded to Payments team", class: input_classes)
    end
  end

  def active_list
    div(class: "border-t border-gray-200 dark:border-gray-700 pt-3") do
      h3(class: "text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400 mb-2") do
        "Active delegates"
      end
      if @active_delegations.empty?
        p(class: "text-sm text-gray-500 dark:text-gray-400") { "No active delegates." }
      else
        ul(class: "space-y-1") { @active_delegations.each { |d| delegation_row(d) } }
      end
    end
  end

  def delegation_row(delegation)
    li(class: "flex items-center justify-between gap-2 text-sm text-gray-800 dark:text-gray-200") do
      span do
        plain(delegation.delegate&.name.presence || delegation.delegate&.email || "Unknown")
        if delegation.expires_at.present?
          span(class: "text-gray-500 dark:text-gray-400") { " · until #{delegation.expires_at.to_date.strftime('%-d %b %Y')}" }
        end
      end
      revoke_button(delegation)
    end
  end

  def revoke_button(delegation)
    form(action: assessment_delegation_path(@assignment, delegation), method: "post",
         data: { turbo_confirm: "Revoke this delegation? Existing ratings are kept." }, class: "inline") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")
      button(type: "submit", aria: { label: "Revoke delegation" },
             class: "text-gray-400 hover:text-red-600 dark:hover:text-red-400 text-lg leading-none cursor-pointer") do
        "×"
      end
    end
  end

  def label_classes
    "block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1"
  end

  def input_classes
    "w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-2.5 py-1.5 text-sm text-gray-900 dark:text-white " \
      "focus:outline-none focus:ring-2 focus:ring-primary"
  end
end
