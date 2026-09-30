# frozen_string_literal: true

# Marks alignment against a role complete (ADR-22): the home role by
# default, or another named with `as_role_id`. The gate is per role: every
# cell the role reads at the conversation's level must carry an agreed
# value, and PM3's cells never block E3's completion or the reverse.
#
# Two layers, as before per-role alignment: the read-model count here gives
# the caller the remaining number, then the counted cells go into the
# aggregate (`required_cell_keys`), which re-checks them atomically against
# the stream.
#
# The reporting manager only ({AssessmentPolicy#complete_alignment?}).
#
# Write — :in_app approval: completion formalises the record.
class Operations::Assessments::CompleteAlignment < Operations::Base
  include Operations::Assessments::AlignmentLens

  description "Mark the alignment conversation complete for one of your direct reports — against their own " \
              "role, or against another role with as_role_id. Every current-level cell of that role must " \
              "carry an agreed rating."
  category :write
  approval :in_app

  parameter :assignment_id, String, required: true
  # The role whose alignment completes; blank = the home role.
  parameter :as_role_id, String
  parameter :as_level_ordinal, Integer

  def policy_check
    authorize assignment, :show?
    authorize_alignment!(:complete_alignment?)
  end

  # @return [Hash] `{ framework_id, cycle_id, role_id, role_code,
  #   level_ordinal, home, status }`
  # @raise [Operations::Base::ParameterError] naming how many current-level
  #   cells still need an agreed rating
  def perform
    cycle = open_cycle!
    ordinal = conversation_level(cycle.cycle_id)
    coverage = Assessments::LevelCoverage.new(
      person_id: assignment.person_id, framework_id: assignment.framework_id, cycle_id: cycle.cycle_id,
      role_id: alignment_role.role_id, level_ordinal: ordinal
    ).call(include_aligned: true)
    refuse_incomplete!(coverage)

    PersonDevelopment::CommandHandler.new.complete_alignment(
      assignment.person_id, assignment.framework_id, cycle.cycle_id,
      completed_by_id: context.person&.id, role_id: alignment_role.role_id,
      required_cell_keys: coverage[:current_level_cell_keys]
    )

    { framework_id: assignment.framework_id, cycle_id: cycle.cycle_id,
      **alignment_role_payload(ordinal), status: alignment_status(cycle.cycle_id) }
  end

  private

  # The level the conversation was started about — the home level for the
  # home role.
  def conversation_level(cycle_id)
    return alignment_lens.home_level.ordinal if alignment_lens.home_role?

    AssessmentCycleRoleAlignment.find_by(cycle_id: cycle_id, person_id: assignment.person_id,
                                         role_id: alignment_role.role_id)&.level_ordinal || alignment_lens.level.ordinal
  end

  # A role with no cells at the level never blocks — there is nothing to align.
  def refuse_incomplete!(coverage)
    return unless coverage[:total].positive? && !coverage[:aligned_complete]

    remaining = coverage[:total] - coverage[:aligned_rated]
    raise Operations::Base::ParameterError,
      "#{remaining} current-level #{'capability'.pluralize(remaining)} still " \
      "#{remaining == 1 ? 'needs' : 'need'} an agreed rating before alignment can be marked complete."
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
