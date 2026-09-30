# frozen_string_literal: true

# "Stop exploring" — closing a declared exploration (ADR-22) with what came
# of it, which the other party is told. Mounted with the page's other
# embedded modals.
class Views::Assessments::StopExplorationModal < Views::Base
  include Views::Assessments::ExplorationModalForm

  ID = "stop-exploration-modal"

  OUTCOMES = {
    "pursue" => [ "Pursue it", "Work towards %<code>s." ],
    "not_now" => [ "Not now", "Set it aside for now." ],
    "moved" => [ "Moved", "Now in the role." ]
  }.freeze

  # @param lens [Assessments::Lens] the page's lens, to return to
  # @param exploration [AssessmentExploration] the open exploration
  # @param assessment_id [String]
  # @param other_party [String] who is told — "your manager", "Alex"
  def initialize(lens:, exploration:, assessment_id:, other_party:)
    @lens = lens
    @exploration = exploration
    @assessment_id = assessment_id
    @other_party = other_party
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Stop exploring #{@exploration.code}?", standalone: false) do |modal|
      modal.body do
        exploration_form(action: assessment_exploration_closure_path(@assessment_id, @exploration.id),
                         submit: "Stop exploring", submitting: "Stopping…") { outcome_fields }
      end
    end
  end

  private

  def outcome_fields
    fieldset do
      legend(class: "text-sm font-medium text-gray-700 dark:text-gray-200") { "What came of it?" }
      p(class: "text-xs text-gray-600 dark:text-gray-300") { "#{@other_party.upcase_first} is told." }
      div(class: "mt-2 space-y-2") do
        OUTCOMES.each_with_index { |(value, (name, hint)), index| outcome_option(value, name, hint, index) }
      end
    end
  end

  def outcome_option(value, name, hint, index)
    field_id = "#{ID}-outcome-#{value}"
    label(for: field_id, class: "flex items-start gap-2 text-sm text-gray-800 dark:text-gray-100 cursor-pointer") do
      input(type: "radio", id: field_id, name: "outcome", value: value, required: index.zero?,
            class: "mt-0.5 accent-primary")
      span do
        span(class: "font-medium") { name }
        plain " — "
        span(class: "text-gray-600 dark:text-gray-300") { Kernel.format(hint, code: @exploration.code) }
      end
    end
  end
end
