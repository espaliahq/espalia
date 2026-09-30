# frozen_string_literal: true

# Starts alignment against a role (ADR-22): the home role by default, or
# another role named with `as_role_id` / `as_level_ordinal` — "Start
# alignment against PM3". From that moment the manager's ratings on the
# role's cells are disclosed to the assessee and self and manager ratings
# on them freeze; cells where both already agree are agreed automatically.
#
# The reporting manager only — never a delegate, never an admin outside the
# chain ({AssessmentPolicy#start_alignment?}).
#
# Write — :in_app approval: it discloses the manager's ratings to the
# assessee and freezes both parties' ratings, which can't be undone.
class Operations::Assessments::StartAlignment < Operations::Base
  include Operations::Assessments::AlignmentLens

  description "Start the alignment conversation for one of your direct reports — against their own role, or " \
              "against another role or level with as_role_id / as_level_ordinal. Discloses your ratings on " \
              "that role's cells to the report and freezes both parties' ratings there."
  category :write
  approval :in_app

  parameter :assignment_id, String, required: true
  # Another role in the framework to align against; blank = the home role.
  parameter :as_role_id, String
  # The level of that role the conversation is about; blank = the home
  # level, or the role's level nearest it.
  parameter :as_level_ordinal, Integer

  def policy_check
    authorize assignment, :show?
    authorize_alignment!(:start_alignment?)
  end

  # @return [Hash] `{ framework_id, cycle_id, role_id, role_code,
  #   level_ordinal, home, status }`
  def perform
    cycle = open_cycle!
    level = alignment_lens.home_role? ? alignment_lens.home_level : alignment_lens.level
    scope = alignment_lens.home_role? ? alignment_lens.home_scope : alignment_lens.scope

    PersonDevelopment::CommandHandler.new.start_alignment(
      assignment.person_id, assignment.framework_id, cycle.cycle_id,
      started_by_id: context.person&.id, role_id: alignment_role.role_id,
      level_ordinal: level.ordinal, cell_keys: scope.cells.to_a
    )

    { framework_id: assignment.framework_id, cycle_id: cycle.cycle_id,
      **alignment_role_payload(level.ordinal), status: alignment_status(cycle.cycle_id) }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
