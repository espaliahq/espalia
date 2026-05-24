# frozen_string_literal: true

# Returns one assessment's top-level structure — the framework it's
# against (full {Mcp::FrameworkSerializer} payload) plus an overlay of
# assignment-specific metadata (role / level the assessee is at, the
# currently open cycle, participant status in that cycle).
#
# Read-only; scoped by AssessmentPolicy#show?
# (owns_assessment? || manages_assessee?).
#
# The framework payload is a strict subset of this payload's `framework:`
# subtree — same keys, same nesting — so an LLM that learned the
# `frameworks_get` schema needs zero new schema knowledge to consume
# this. Per-category scoring rollup is deliberately deferred to a follow-
# up slice that also ships `assessment_capability_get`; that slice will
# wire MatrixDataBuilder / PersonDevelopment::Scoring into the overlay.
class Operations::Assessments::Get < Operations::Base
  description "Fetch one assessment's framework structure and the assessee's current role/level/cycle status."
  category :read
  approval :none

  parameter :assignment_id, String, required: true

  def policy_check
    authorize assignment, :show?
  end

  # @return [Hash] same payload as {Operations::Frameworks::Get} under
  #   `:framework`, plus `:assignment` (role + level + person identity)
  #   and `:current_cycle` (id, name, status, planned_end_at) or nil.
  def perform
    {
      framework: Mcp::FrameworkSerializer.framework(assignment.framework),
      assignment: assignment_payload,
      current_cycle: cycle_payload(assignment.current_open_cycle)
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def assignment_payload
    {
      id: assignment.id,
      role: { id: assignment.role.role_id, code: assignment.role.code, name: assignment.role.name },
      level: { id: assignment.level.level_id, ordinal: assignment.level.ordinal, title: assignment.level.title },
      assessee: { id: assignment.person_id }
    }
  end

  def cycle_payload(cycle)
    return nil unless cycle

    {
      id: cycle.cycle_id,
      name: cycle.name,
      status: cycle.status,
      planned_end_at: cycle.planned_end_at&.iso8601,
      participant_status: assignment.current_open_cycle_participation&.status
    }
  end
end
