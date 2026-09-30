# frozen_string_literal: true

# Re-opens a completed alignment against a role (ADR-22) — the home role by
# default, or another named with `as_role_id` — so the manager can correct
# a completion made by accident. The agreed per-cell values are preserved —
# the manager resumes where they left off and re-completes via the normal
# "mark alignment complete" path.
#
# Manager-only and only while the cycle is still open and the role's
# alignment is completed (enforced by {AssessmentPolicy#reopen_alignment?}).
#
# Write — :mcp_client approval. The action is recoverable (the manager can
# simply re-complete), so it doesn't need the in-app confirmation gate that
# irreversible lifecycle operations use.
class Operations::Assessments::ReopenAlignment < Operations::Base
  include Operations::Assessments::AlignmentLens

  description "Re-open a completed alignment so the manager can correct it; agreed values are preserved. " \
              "Pass as_role_id to re-open an alignment against another role."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  # The role whose alignment re-opens; blank = the home role.
  parameter :as_role_id, String
  parameter :as_level_ordinal, Integer

  def policy_check
    authorize assignment, :show?
    authorize_alignment!(:reopen_alignment?)
  end

  # @return [Hash] `{ framework_id, cycle_id, status, role_id, role_code,
  #   level_ordinal, home }` — status is the role's alignment after
  #   re-opening (expected "aligning").
  def perform
    cycle = open_cycle!

    PersonDevelopment::CommandHandler.new.reopen_alignment(
      assignment.person_id, assignment.framework_id, cycle.cycle_id,
      reopened_by_id: context.person&.id, role_id: alignment_role.role_id
    )

    { framework_id: assignment.framework_id, cycle_id: cycle.cycle_id,
      status: alignment_status(cycle.cycle_id), **alignment_role_payload(conversation_level(cycle.cycle_id)) }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
