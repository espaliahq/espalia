# frozen_string_literal: true

# Handles self-rating submissions during an assessment.
#
# Dispatches SelfRated / SelfRatingRevised commands through the
# PersonDevelopment command handler. Returns Turbo Stream responses
# to update the frequency selector, scoring panel, and category header.
#
class Assessments::RatingsController < ApplicationController
  before_action :set_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/ratings
  def create
    rating_params = params.expect(rating: [ :capability_stable_id, :level_ordinal, :frequency, :comment ])
    capability_stable_id = rating_params[:capability_stable_id]
    level_ordinal = rating_params[:level_ordinal].to_i
    frequency = rating_params[:frequency]
    comment = rating_params[:comment]

    handler = PersonDevelopment::CommandHandler.new

    existing = AssessmentLevelRating.find_by(
      person_id: @person.id,
      framework_id: @assignment.framework_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal
    )

    if existing&.self_rated_frequency.present?
      handler.revise_self_rating(
        @person.id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal, frequency: frequency,
        rationale: "Updated during self-assessment", comment: comment
      )
    else
      handler.rate_self(
        @person.id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal, frequency: frequency, comment: comment
      )
    end

    respond_with_turbo_stream(capability_stable_id, level_ordinal)
  rescue RuntimeError => e
    render turbo_stream: turbo_stream.replace(
      "rating-#{capability_stable_id}-#{level_ordinal}",
      render_to_string(
        Views::Assessments::RatingError.new(message: e.message),
        layout: false
      )
    ), status: :unprocessable_content
  end

  private

  def set_person
    tenant = ActsAsTenant.current_tenant
    tenant_user = ActsAsTenant.without_tenant do
      current_user.tenant_users.find_by(tenant: tenant)
    end
    @person = tenant_user&.person
    head :forbidden unless @person
  end

  def set_assignment
    return if @person.nil?

    @assignment = PersonFrameworkAssignment.for_person(@person.id)
      .find_by!(framework_id: params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def respond_with_turbo_stream(capability_stable_id, level_ordinal)
    # Reload fresh data for the turbo stream response
    framework = FrameworkState::Framework.find_by!(framework_id: @assignment.framework_id)
    role = FrameworkState::Role.find_by!(role_id: @assignment.role_id)
    level = FrameworkState::Level.find_by!(level_id: @assignment.level_id)
    categories = FrameworkState::CapabilityCategory
      .where(framework_id: @assignment.framework_id)
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)

    matrix_data = Assessments::MatrixDataBuilder.new(
      framework: framework, role: role, level: level,
      person_id: @person.id, categories: categories
    ).build

    # Find the capability's category for targeted category header update
    category_id = find_category_id(capability_stable_id, matrix_data)

    # Find updated cell data for this specific rating
    cell_data = find_cell_data(capability_stable_id, level_ordinal, matrix_data)

    render turbo_stream: [
      turbo_stream.replace(
        "cell-#{capability_stable_id}-#{level_ordinal}",
        render_to_string(
          Views::Assessments::MatrixCell.new(
            cell_data: cell_data,
            capability_stable_id: capability_stable_id,
            ordinal: level_ordinal,
            person_level: matrix_data[:person_level],
            framework_id: @assignment.framework_id
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "scoring-panel",
        render_to_string(
          Views::Assessments::ScoringPanel.new(
            scoring: matrix_data[:scoring],
            categories: matrix_data[:categories],
            person_level: matrix_data[:person_level]
          ),
          layout: false
        )
      ),
      (turbo_stream.replace(
        "category-status-#{category_id}",
        render_to_string(
          Views::Assessments::CategoryStatus.new(
            category_id: category_id,
            category_result: matrix_data[:scoring][:category_results][category_id]
          ),
          layout: false
        )
      ) if category_id)
    ].compact
  end

  def find_category_id(capability_stable_id, matrix_data)
    matrix_data[:categories].each do |cat_data|
      cat_data[:capabilities].each do |cap_data|
        return cat_data[:category].category_id if cap_data[:capability].stable_id == capability_stable_id
      end
    end
    nil
  end

  def find_cell_data(capability_stable_id, level_ordinal, matrix_data)
    matrix_data[:categories].each do |cat_data|
      cat_data[:capabilities].each do |cap_data|
        if cap_data[:capability].stable_id == capability_stable_id
          return cap_data[:cells][level_ordinal]
        end
      end
    end
    nil
  end
end
