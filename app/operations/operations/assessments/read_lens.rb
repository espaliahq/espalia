# frozen_string_literal: true

# The lens an assessment read tool reads through (ADR-22): the home role and
# level unless the caller names another with `as_role_id` /
# `as_level_ordinal`. The same {Assessments::Lens} the web resolves, so an
# agent's number is the number the person sees on that page.
#
# Including Operations declare `parameter :as_role_id, String`,
# `parameter :as_level_ordinal, Integer` and `cycle_id` with
# {CYCLE_ID_SCHEMA}, and read `assignment`. A `cycle_id` reads a past cycle
# the person joined: its ratings and score at its own role and level, as the
# web's read-only past-cycle page shows them
# (https://github.com/mr-yum/growth-os/issues/669).
module Operations::Assessments::ReadLens
  # @return [Hash] the `cycle_id` parameter's schema
  CYCLE_ID_SCHEMA = {
    description: "A cycle the person joined on this framework, from past_cycles. Ratings and scores are then that " \
                 "cycle's, at its own role and level. Omit for the open cycle."
  }.freeze

  private

  # @return [Assessments::Lens, nil] nil when the assignment's home role or
  #   level is gone — the score then reports `assignment_structure_unavailable`
  # @raise [Operations::Base::ParameterError] for a role or level the
  #   framework doesn't have
  def read_lens
    return @read_lens if defined?(@read_lens)

    @read_lens = Assessments::Lens.resolve(
      assignment: assignment, as_role: params[:as_role_id], as_level: params[:as_level_ordinal],
      cycle_id: params[:cycle_id]
    )
  rescue Assessments::Lens::NotFound => e
    raise Operations::Base::ParameterError, e.message
  rescue ActiveRecord::RecordNotFound
    @read_lens = nil
  end

  # The viewer's perspective, resolved exactly as the web resolves it for
  # the same lens — the assessee must not read the manager's ratings
  # through a score before they are disclosed.
  def viewer_context
    @viewer_context ||= Assessments::ViewerContext.for(assignment: assignment, authorization: context, lens: read_lens)
  end

  # `{ home:, lens: }` — whether the record's role and the lens role each
  # read this capability, so an agent can't report a number from a lens
  # role as the assessment of record.
  #
  # @return [Hash, nil]
  def in_role(stable_id)
    return nil unless read_lens

    { home: read_lens.home_scope.capability_stable_ids.include?(stable_id),
      lens: read_lens.scope.capability_stable_ids.include?(stable_id) }
  end
end
