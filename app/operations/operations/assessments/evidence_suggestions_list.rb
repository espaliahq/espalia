# frozen_string_literal: true

# The pending placement suggestions on an assessment — where the model thinks
# feedback belongs, for a person to accept or dismiss — optionally for one
# item. Each carries the capability, level, valence, a confidence from 0 to 1
# and a rationale quoting the feedback, plus the model and prompt version that
# produced it.
#
# Read-only. Across an assessment: {EvidencePolicy#index?} (the people who
# see all its evidence). For one item: {EvidencePolicy#add_link?}, which also
# admits its author — the people who can act on the suggestions.
class Operations::Assessments::EvidenceSuggestionsList < Operations::Base
  include Operations::Assessments::EvidenceSuggestion

  description "List the pending placement suggestions on an assessment, or for one feedback / evidence item: " \
              "the suggested capability × level and valence, a confidence from 0 to 1 and a rationale quoting " \
              "the feedback. Accept or dismiss them with assessments_accept_evidence_suggestion / " \
              "assessments_dismiss_evidence_suggestion."
  category :read
  approval :none

  parameter :assignment_id, String, required: true
  parameter :evidence_id, String, allow_blank: false

  def policy_check
    if params[:evidence_id]
      authorize item, :add_link?, policy_class: EvidencePolicy
    else
      authorize assignment, :index?, policy_class: EvidencePolicy
    end
  end

  # @return [Hash] `{ assignment_id, evidence_id, suggestions: [...] }`, most
  #   confident first within each item
  def perform
    rows = scope.most_confident_first.to_a
    names = capability_names(rows)
    { assignment_id: assignment.id, evidence_id: params[:evidence_id],
      suggestions: rows.map { |row| suggestion_payload(row, names) } }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def item
    @item ||= EvidenceItem.for_person(assignment.person_id).for_framework(assignment.framework_id)
      .find(params[:evidence_id])
  end

  def scope
    rows = EvidencePlacementSuggestion.pending.where(person_id: assignment.person_id, framework_id: assignment.framework_id)
    rows = rows.where(evidence_id: item.id) if params[:evidence_id]
    rows.where(evidence_id: EvidenceItem.active.select(:id))
  end
end
