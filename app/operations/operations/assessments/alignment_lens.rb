# frozen_string_literal: true

# The role an alignment Operation acts on (ADR-22): the home role unless the
# caller names another with `as_role_id` / `as_level_ordinal` — the same
# pair a lens is read through, so "Start alignment against PM3" on the page
# and over MCP resolve the same role.
#
# Pundit's `authorize` passes no arguments, so the per-role predicates on
# {AssessmentPolicy} are asked here directly.
#
# Including Operations declare `parameter :as_role_id, String` and
# `parameter :as_level_ordinal, Integer`, and read `assignment`.
module Operations::Assessments::AlignmentLens
  private

  # @return [Assessments::Lens]
  # @raise [Operations::Base::ParameterError] for a role or level the
  #   framework doesn't have
  def alignment_lens
    @alignment_lens ||= Assessments::Lens.resolve(
      assignment: assignment, as_role: params[:as_role_id], as_level: params[:as_level_ordinal]
    )
  rescue Assessments::Lens::NotFound => e
    raise Operations::Base::ParameterError, e.message
  end

  # @return [FrameworkState::Role] the role the alignment is against
  def alignment_role
    alignment_lens.home_role? ? alignment_lens.home_role : alignment_lens.role
  end

  # @return [String, nil] the role for the policy; nil for the home role
  def policy_role_id
    alignment_lens.home_role? ? nil : alignment_lens.role.role_id
  end

  # @param query [Symbol] a per-role {AssessmentPolicy} predicate
  # @raise [Pundit::NotAuthorizedError]
  def authorize_alignment!(query)
    policy = AssessmentPolicy.new(context, assignment)
    return if policy.public_send(query, role_id: policy_role_id)

    raise Pundit::NotAuthorizedError.new(query: query, record: assignment, policy: policy)
  end

  # @return [String] "aligning" or "aligned" — the role's alignment after the call
  def alignment_status(cycle_id)
    if alignment_lens.home_role?
      assignment.current_open_cycle_participation&.status
    else
      AssessmentCycleRoleAlignment.find_by(cycle_id: cycle_id, person_id: assignment.person_id,
                                           role_id: alignment_role.role_id)&.status
    end
  end

  # @return [Hash] names the role in every alignment payload
  def alignment_role_payload(level_ordinal)
    { role_id: alignment_role.role_id, role_code: alignment_role.code, level_ordinal: level_ordinal,
      home: alignment_lens.home_role? }
  end

  def open_cycle!
    assignment.current_open_cycle || raise(Operations::Base::ParameterError, "no open assessment cycle")
  end
end
