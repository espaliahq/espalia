# frozen_string_literal: true

# Declares an exploration of another role or level (ADR-22) — "we've agreed
# to explore PM3". An intent fact both parties see on their lists; it rates
# nothing, so it needs no open cycle. The target is named the way a lens is
# (`as_role_id` / `as_level_ordinal`) and can't be the role and level the
# assessment is of; one exploration per target role is open at a time.
#
# The assessee, their reporting manager or an active rating delegate
# ({AssessmentPolicy#start_exploration?}). The other party is notified.
#
# Write — :mcp_client approval: additive and closable, and it changes no
# one's ratings or permissions.
class Operations::Assessments::StartExploration < Operations::Base
  include Operations::Assessments::ExplorationPayload

  description "Declare that a person is exploring another role or level — an intent both they and their manager " \
              "see, not a rating. Name the target like a lens: as_role_id (blank = their own role) and/or " \
              "as_level_ordinal; it can't be the role and level they hold, and only one exploration per role " \
              "is open at a time. The other party is notified."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  # The role to explore; blank = the home role (a vertical exploration).
  parameter :as_role_id, String
  # The level of that role; blank = the home level, or the role's level
  # nearest it.
  parameter :as_level_ordinal, Integer
  parameter :note, String
  requires_any_of :as_role_id, :as_level_ordinal

  def policy_check
    authorize assignment, :start_exploration?
  end

  # @return [Hash] the exploration (see {ExplorationPayload}) plus
  #   `assignment_id` and `framework_id`
  def perform
    raise ParameterError, "#{target.code} is the role and level this assessment is of" if target.home?
    if (open = open_exploration)
      raise ParameterError, "An exploration of #{open.label || target.role.name} is already open"
    end

    exploration_id = SecureRandom.uuid_v7
    PersonDevelopment::CommandHandler.new.start_exploration(
      assignment.person_id, assignment.framework_id, exploration_id,
      target_role_id: target.role.role_id, target_level_id: target.level.level_id,
      target_level_ordinal: target.level.ordinal, started_by_id: context.person&.id,
      note: params[:note].to_s.strip.presence
    )

    { assignment_id: assignment.id, framework_id: assignment.framework_id,
      **exploration_payload(AssessmentExploration.find(exploration_id)) }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # @return [Assessments::Lens]
  def target
    @target ||= Assessments::Lens.resolve(
      assignment: assignment, as_role: params[:as_role_id], as_level: params[:as_level_ordinal]
    )
  rescue Assessments::Lens::NotFound => e
    raise ParameterError, e.message
  end

  def open_exploration
    AssessmentExploration.open_of_role(assignment, target.role.role_id)
  end
end
