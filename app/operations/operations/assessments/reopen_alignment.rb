# frozen_string_literal: true

# Re-opens a completed alignment, returning the cycle to the `aligning`
# phase so the manager can correct a completion made by accident. The
# agreed per-cell values are preserved — the manager resumes where they
# left off and re-completes via the normal "mark alignment complete" path.
#
# Manager-only and only while the cycle is still open + currently aligned
# (enforced by {AssessmentPolicy#reopen_alignment?}).
#
# Write — :mcp_client approval. The action is recoverable (the manager can
# simply re-complete), so it doesn't need the in-app confirmation gate that
# irreversible lifecycle operations use.
class Operations::Assessments::ReopenAlignment < Operations::Base
  description "Re-open a completed alignment so the manager can correct it; agreed values are preserved."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true

  def policy_check
    authorize assignment, :reopen_alignment?
  end

  # @return [Hash] `{ framework_id, cycle_id, status }` — status is the
  #   participant's lifecycle status after re-opening (expected "aligning").
  def perform
    cycle = assignment.current_open_cycle
    raise Operations::Base::ParameterError, "no open assessment cycle" if cycle.nil?

    PersonDevelopment::CommandHandler.new.reopen_alignment(
      assignment.person_id, assignment.framework_id, cycle.cycle_id,
      reopened_by_id: context.person&.id
    )

    {
      framework_id: assignment.framework_id,
      cycle_id: cycle.cycle_id,
      status: assignment.current_open_cycle_participation&.status
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
