# frozen_string_literal: true

# The cell a rating Operation writes, checked once for web and MCP alike.
#
# A rating is a fact about the person at a capability × level (ADR-22), made
# through a lens: `as_role_id` names the role whose examples the rater was
# reading, and defaults to the home role. The level must be one of that
# role's levels and the cell must be one the role reads — a capability it
# binds, with an expectation at that level.
#
# Freeze is per cell (ADR-22): a self or manager rating is refused on a cell
# any started alignment reads, and an agreed value where no alignment reading
# the cell is in progress — the rules the aggregate enforces, checked here
# first so web and MCP get a clear refusal instead of a domain error.
#
# Including Operations declare `parameter :as_role_id, String` and read
# `assignment`.
module Operations::Assessments::RatingCell
  private

  # @return [Assessments::Lens] the lens the write is made through
  # @raise [Operations::Base::ParameterError] for a role or level the
  #   framework doesn't have, or a cell the role doesn't read
  def rating_lens
    @rating_lens ||= begin
      lens = Assessments::Lens.resolve(
        assignment: assignment, as_role: params[:as_role_id], as_level: params[:level_ordinal]
      )
      unless lens.scope.include?(params[:capability_stable_id], params[:level_ordinal])
        raise Operations::Base::ParameterError,
          "#{lens.role.code} has no expectation for capability #{params[:capability_stable_id]} " \
          "at level #{params[:level_ordinal]}"
      end
      lens
    end
  rescue Assessments::Lens::NotFound => e
    raise Operations::Base::ParameterError, e.message
  end

  # The provenance stamp for a write through a lens: the lens role when it
  # isn't the home role, nil otherwise. Never a scoping key — a shared-cell
  # rating made through another role is still the home rating.
  #
  # @return [String, nil]
  def via_role_id
    rating_lens.home_role? ? nil : rating_lens.role.role_id
  end

  # @raise [Pundit::NotAuthorizedError] when a started alignment froze the
  #   cell's self and manager ratings
  def refuse_frozen_cell!
    alignment = rating_disclosure.frozen_by(params[:capability_stable_id], params[:level_ordinal])
    return unless alignment

    raise Pundit::NotAuthorizedError, "Frozen — alignment against #{alignment.code} has started"
  end

  # @raise [Pundit::NotAuthorizedError] when no alignment reading the cell
  #   is in progress, or a completed one already agreed it
  def refuse_locked_agreement!
    agreed = AssessmentLevelRating.find_by(
      cycle_id: assignment.current_open_cycle&.cycle_id, person_id: assignment.person_id,
      capability_stable_id: params[:capability_stable_id], level_ordinal: params[:level_ordinal]
    )&.aligned_frequency.present?
    return unless rating_disclosure.agreed_value_locked?(params[:capability_stable_id], params[:level_ordinal],
                                                         agreed: agreed)

    raise Pundit::NotAuthorizedError, "No alignment reading this cell is in progress"
  end

  def rating_disclosure
    @rating_disclosure ||= Assessments::Disclosure.for(
      lens: rating_lens, participant_status: assignment.current_open_cycle_participation&.status
    )
  end
end
