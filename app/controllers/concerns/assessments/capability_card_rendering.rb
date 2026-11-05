# frozen_string_literal: true

# Reads a person's assessment the way the page does and builds one
# capability card the way the matrix frame builds it.
#
# Shared by `AssessmentsController` (the matrix frame and the chip-click
# card swap, [#488](https://github.com/mr-yum/growth-os/issues/488)) and
# `Assessments::CommentsController` (a cell comment's response swaps that
# card's thread and chip, [#625](https://github.com/mr-yum/growth-os/issues/625)), so
# neither response can drift from the card the page rendered.
#
# Requires `@assignment` (a `PersonFrameworkAssignment`) and `current_person`.
module Assessments::CapabilityCardRendering
  extend ActiveSupport::Concern
  include AssessmentVisibility

  private

  # The role and level the page is read against (`as_role` / `as_level`),
  # in the cycle `cycle_id` names, else the open one — resolved once per
  # request and only after `authorize`, so a pair or cycle the assignment
  # doesn't have is a 404 to a permitted viewer and nobody else.
  #
  # @return [Assessments::Lens]
  # @raise [Assessments::Lens::NotFound]
  def lens
    @lens ||= Assessments::Lens.resolve(assignment: @assignment, as_role: params[:as_role], as_level: params[:as_level],
                                        cycle_id: params[:cycle_id])
  end

  # A past cycle is read-only: every write affordance is off, whatever the
  # viewer could do on the open cycle.
  def past_cycle?
    lens.past?
  end

  # Returns the assessment context based on the viewer's relationship and
  # the cycle's lifecycle. Once the manager has formally started alignment
  # (cycle status `aligning` or `aligned`), both parties view the assessment
  # in alignment mode automatically — there is no opt-in/opt-out toggle.
  #
  # @return [Symbol] :self, :manager, or :alignment
  def assessment_context
    @assessment_context ||=
      Assessments::ViewerContext.for(assignment: @assignment, authorization: pundit_user, lens: lens)
  end

  def load_assessment_data
    @matrix_data = Assessments::MatrixDataBuilder.for_lens(
      lens: lens,
      context: assessment_context,
      viewer_person_id: current_person&.id,
      viewer_sees_all_evidence: viewer_sees_all_evidence?
    )
    apply_viewer_rating_lock
  end

  # View-only manager-side viewers (manager-chain ancestors who are neither
  # the recorded reporting manager nor an active rating delegate) get static
  # rating pills — the rating policies would reject their POSTs, so no
  # interactive affordance should render. Rating-capable viewers keep the
  # lifecycle-derived flags untouched.
  def apply_viewer_rating_lock
    return unless viewer_is_manager?

    @matrix_data[:individual_ratings_frozen] = true unless assignment_policy.create_manager_rating?
    if assessment_context == :alignment && !assignment_policy.create_alignment_rating?
      @matrix_data[:alignment_locked] = true
    end
  end

  def assignment_policy
    @assignment_policy ||= AssessmentPolicy.new(pundit_user, @assignment)
  end

  # The arguments every matrix render takes, whether the whole frame or one
  # card, so the two can't drift.
  #
  # @return [Hash]
  def matrix_card_args
    {
      matrix_data: @matrix_data,
      context: assessment_context,
      viewer_is_manager: viewer_is_manager?,
      viewer_person_id: current_person&.id,
      can_create_evidence: !past_cycle? && viewer_can_create_evidence?,
      can_request_evidence: !past_cycle? && viewer_can_request_evidence?,
      can_relink_others_evidence: !past_cycle? && viewer_can_relink_others_evidence?,
      can_comment: !past_cycle? && viewer_can_comment?,
      viewer_is_tenant_admin: viewer_is_tenant_admin?
    }
  end

  # One card, unrendered, built as the matrix frame builds it. Call after
  # `load_assessment_data`.
  #
  # @param stable_id [String] the capability's stable_id
  # @param selected_levels [Hash{String => Integer}] the card's rendered level
  # @return [Views::Assessments::CapabilityCard, nil] nil when the matrix
  #   doesn't show it
  def capability_card_view(stable_id, selected_levels:)
    Views::Assessments::AssessmentMatrix.new(
      **matrix_card_args, selected_levels: selected_levels, assessment_id: @assignment.id
    ).capability_card(stable_id)
  end

  # Whether the current viewer is permitted to record evidence on this
  # assessment. V1 allows any tenant member with a Person to record peer
  # evidence — see {EvidencePolicy#create?}.
  def viewer_can_create_evidence?
    return false unless current_person

    EvidencePolicy.new(pundit_user, @assignment).create?
  end

  # Whether to render the per-cell "Request evidence" affordance — same
  # population as who may create a request (assessee / manager chain / active
  # rating delegate / tenant admin), enforced again server-side on submit.
  def viewer_can_request_evidence?
    return false unless current_person

    EvidenceRequestPolicy.new(pundit_user, @assignment).request?
  end

  # Whether the current viewer is permitted to post comments on this
  # assessment. V1 allows any tenant member with a Person to comment —
  # the conversation lane is intentionally broader than the evidence
  # lane. Authority for editing/deleting is gated per-card in the view.
  def viewer_can_comment?
    return false unless current_person

    PersonDevelopmentCommentPolicy.new(pundit_user, @assignment).create?
  end

  # Tenant admins gain a delete-only override for moderation. Not a
  # general edit override — only the author can rewrite their own words.
  def viewer_is_tenant_admin?
    current_user&.global_admin? || current_tenant_user&.admin? || false
  end
end
