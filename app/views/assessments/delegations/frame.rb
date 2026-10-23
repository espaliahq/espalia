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
    render Components::Kit::Alert.new(tone: :danger, class: "mb-3") { @error }
  end

  def add_form
    form(action: assessment_delegations_path(@assignment), method: "post", class: "mb-4") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

      person_field
      expiry_field
      reason_field
      div(class: "mt-3 flex justify-end") do
        render Components::Kit::Button.new(tone: :brand, size: :sm, type: :submit) { "Add delegate" }
      end
    end
  end

  def person_field
    div(class: "mb-3") do
      label(for: "delegation_delegate_person_id", class: label_classes) { "Delegate to" }
      select(id: "delegation_delegate_person_id", name: "delegation[delegate_person_id]",
             required: true, class: Components::Kit::Field::SELECT) do
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
            class: Components::Kit::Field::INPUT)
    end
  end

  def reason_field
    div(class: "mb-1") do
      label(for: "delegation_reason", class: label_classes) { "Reason (optional)" }
      input(id: "delegation_reason", type: "text", name: "delegation[reason]",
            maxlength: 200, placeholder: "e.g. seconded to Payments team",
            class: Components::Kit::Field::INPUT)
    end
  end

  def active_list
    div(class: "border-t border-default pt-3") do
      h3(class: "text-xs font-medium uppercase tracking-wide text-muted mb-2") do
        "Active delegates"
      end
      if @active_delegations.empty?
        p(class: "text-sm text-muted") { "No active delegates." }
      else
        ul(class: "space-y-1") { @active_delegations.each { |d| delegation_row(d) } }
      end
    end
  end

  def delegation_row(delegation)
    li(class: "flex items-center justify-between gap-2 text-sm text-default") do
      span do
        plain(delegation.delegate&.name.presence || delegation.delegate&.email || "Unknown")
        if delegation.expires_at.present?
          span(class: "text-muted") { " · until #{delegation.expires_at.to_date.strftime('%-d %b %Y')}" }
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
      render Components::Kit::Button.new(variant: :ghost, tone: :danger, size: :xs, icon: true, type: :submit,
                                         aria_label: "Revoke delegation") do
        span(class: "text-lg leading-none", aria: { hidden: "true" }) { "×" }
      end
    end
  end

  def label_classes
    "block text-xs font-medium text-muted mb-1"
  end
end
