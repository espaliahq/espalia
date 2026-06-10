# frozen_string_literal: true

# Removes a person's framework assignment entirely — the exit from the
# assign → change_role → change_level lifecycle. Used when the person's real
# role no longer maps to any framework role, or to correct an erroneous
# assignment. History is preserved on the PersonDevelopment stream; only the
# assignment read-model row is removed, and the person may be re-assigned later.
#
# Destructive (it removes the assignment and gates all further assessment work
# on that stream behind a re-assignment), so it routes to :in_app approval —
# MCP defers it to the web confirmation flow. The aggregate refuses while the
# person is still enrolled in an open cycle; unenroll first.
class Operations::Assessments::Unassign < Operations::Base
  description "Remove a person's framework assignment (when their real role no longer maps to a framework role)."
  category :destructive
  approval :in_app

  parameter :assignment_id, String, required: true
  parameter :reason,        String

  def policy_check
    authorize assignment, :unassign?
  end

  # @return [Hash] `{ person_id, framework_id, previous_role_id, previous_level_id }`
  def perform
    if assignment.current_open_cycle
      raise Operations::Base::ParameterError,
            "person is still enrolled in an open cycle — unenroll before unassigning"
    end

    previous_role_id  = assignment.role_id
    previous_level_id = assignment.level_id

    PersonDevelopment::CommandHandler.new.unassign_from_framework(
      assignment.person_id, assignment.framework_id,
      reason: params[:reason].presence || "manual",
      unassigned_by: context.person&.id
    )

    {
      person_id: assignment.person_id,
      framework_id: assignment.framework_id,
      previous_role_id: previous_role_id,
      previous_level_id: previous_level_id
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
