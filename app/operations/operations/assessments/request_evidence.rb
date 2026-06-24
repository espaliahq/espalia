# frozen_string_literal: true

# Asks a colleague to provide evidence about a specific capability × level on
# an assessment. Cell-scoped: the response lands pre-linked to that cell.
#
# Write — :mcp_client. It's additive (creates a request + notifies), changes
# no permissions, and a manager asking on behalf of a report is routine.
class Operations::Assessments::RequestEvidence < Operations::Base
  description "Ask a colleague to provide evidence for a capability × level on an assessment."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :requestee_person_id,  String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :message, String
  parameter :due_at, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize assignment, :request?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] { request_id, requestee_person_id, capability_stable_id, level_ordinal, status }
  def perform
    validate_capability_in_framework!
    validate_level_ordinal!
    validate_requestee!

    request_id = SecureRandom.uuid_v7
    PersonDevelopment::CommandHandler.new.request_evidence(
      assignment.person_id, assignment.framework_id, request_id,
      requested_by_id: context.person.id,
      requestee_person_id: params[:requestee_person_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      message: params[:message].presence,
      due_at: params[:due_at].presence
    )

    request = EvidenceRequest.find(request_id)
    {
      request_id: request.id,
      requestee_person_id: request.requestee_person_id,
      capability_stable_id: request.capability_stable_id,
      level_ordinal: request.level_ordinal,
      status: request.status
    }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def validate_requestee!
    person = Person.find_by(id: params[:requestee_person_id], status: "active")
    raise Operations::Base::ParameterError, "requestee_person_id is not an active person in this workspace" if person.nil?
    # The assessee may be asked (a manager nudging them for more evidence); only
    # asking yourself is meaningless.
    raise Operations::Base::ParameterError, "cannot request evidence from yourself" if person.id == context.person.id
  end

  def validate_capability_in_framework!
    in_framework = FrameworkState::Capability
      .joins(:category)
      .where(stable_id: params[:capability_stable_id])
      .merge(FrameworkState::CapabilityCategory.where(framework_id: assignment.framework_id))
      .exists?
    return if in_framework

    raise Operations::Base::ParameterError, "capability_stable_id does not belong to the assignment's framework"
  end

  def validate_level_ordinal!
    return if FrameworkState::Level.exists?(role_id: assignment.role_id, ordinal: params[:level_ordinal])

    raise Operations::Base::ParameterError, "level_ordinal #{params[:level_ordinal]} does not exist for the assignment's role"
  end
end
