# frozen_string_literal: true

# Handles self-rating submissions during an assessment.
#
# Dispatches SelfRated / SelfRatingRevised commands through the
# PersonDevelopment command handler. Returns Turbo Stream responses
# to update the frequency selector, scoring panel, and category header.
#
class Assessments::RatingsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/ratings
  def create
    authorize @assignment, :create_self_rating?

    rating_params = params.expect(rating: [ :capability_stable_id, :level_ordinal, :frequency, :comment ])
    capability_stable_id = rating_params[:capability_stable_id]
    level_ordinal = rating_params[:level_ordinal].to_i
    frequency = rating_params[:frequency]
    comment = rating_params[:comment]

    handler = PersonDevelopment::CommandHandler.new

    existing = AssessmentLevelRating.find_by(
      person_id: current_person.id,
      framework_id: @assignment.framework_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal
    )

    if existing&.self_rated_frequency == frequency
      # Untoggle: clicking the already-selected frequency clears the rating
      handler.clear_self_rating(
        current_person.id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal
      )
    elsif existing&.self_rated_frequency.present?
      handler.revise_self_rating(
        current_person.id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal, frequency: frequency,
        rationale: "Updated during self-assessment", comment: comment
      )
    else
      handler.rate_self(
        current_person.id, @assignment.framework_id, capability_stable_id,
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

  def require_person
    head :forbidden unless current_person
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def user_not_authorized(_exception = nil)
    head :forbidden
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
      person_id: current_person.id, categories: categories
    ).build

    # Find the capability's category for targeted category header update
    category_id = find_category_id(capability_stable_id, matrix_data)

    # Find capability data (cell, contribution, binding, etc.) for targeted updates
    cap_data = find_capability_data(capability_stable_id, matrix_data)
    if cap_data.nil?
      head :not_found
      return
    end
    cell_data = cap_data[:cells][level_ordinal]
    contribution = cap_data[:contribution]
    blocked = matrix_data[:scoring].dig(:capability_statuses, capability_stable_id) == :blocked
    block_reason = matrix_data[:scoring].dig(:block_reasons, capability_stable_id)

    render turbo_stream: [
      turbo_stream.replace(
        "cell-#{capability_stable_id}-#{level_ordinal}",
        render_to_string(
          Views::Assessments::AssessmentCell.new(
            cell_data: cell_data,
            capability_stable_id: capability_stable_id,
            ordinal: level_ordinal,
            person_level: matrix_data[:person_level],
            assessment_id: @assignment.id,
            context: :self
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
            person_level: matrix_data[:person_level],
            mastery_threshold: matrix_data[:mastery_threshold],
            meeting_expectation_threshold: matrix_data[:meeting_expectation_threshold]
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
      ) if category_id),
      (turbo_stream.replace(
        "category-contribution-#{category_id}",
        render_to_string(
          Views::Assessments::CategoryContributionLabel.new(
            category_id: category_id,
            category_result: matrix_data[:scoring][:category_results][category_id]
          ),
          layout: false
        )
      ) if category_id),
      turbo_stream.replace(
        "capability-name-#{capability_stable_id}",
        render_to_string(
          Views::Assessments::CapabilityNameCell.new(
            capability: cap_data[:capability],
            weight: cap_data[:weight],
            mandatory: cap_data[:binding].deficit_threshold&.to_f == 0.0,
            blocked: blocked,
            block_reason: block_reason,
            contribution: contribution,
            has_illustrations: cap_data[:cells].any? { |_, c| c[:illustration_count]&.positive? }
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "matrix-header",
        render_to_string(
          Views::Assessments::MatrixHeader.new(
            merged_levels: matrix_data[:merged_levels],
            person_level: matrix_data[:person_level],
            inferred_level: matrix_data[:inferred_level]
          ),
          layout: false
        )
      )
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

  def find_capability_data(capability_stable_id, matrix_data)
    matrix_data[:categories].each do |cat_data|
      cat_data[:capabilities].each do |cap_data|
        return cap_data if cap_data[:capability].stable_id == capability_stable_id
      end
    end
    nil
  end
end
