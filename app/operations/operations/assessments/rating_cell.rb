# frozen_string_literal: true

# The cell a rating Operation writes, checked once for web and MCP alike.
#
# A rating is a fact about the person at a capability × level (ADR-22), made
# through a lens: `as_role_id` names the role whose examples the rater was
# reading, and defaults to the home role. The level must be one of that
# role's levels and the cell must be one the role reads — a capability it
# binds, with an expectation at that level.
#
# Manager-side writes (manager ratings, alignment) are further held to the
# cells the record reads until per-role alignment exists: a manager rating on
# a cell only another role reads could never be disclosed to the assessee.
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

  # @raise [Pundit::NotAuthorizedError] when a manager-side write targets a
  #   cell the record doesn't read
  def refuse_outside_home_role!
    return if AssessmentPolicy.new(context, assignment)
      .home_cell?(params[:capability_stable_id], params[:level_ordinal])

    raise Pundit::NotAuthorizedError,
      "Manager ratings against another role come with per-role alignment"
  end
end
