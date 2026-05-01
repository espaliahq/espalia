# frozen_string_literal: true

# Handles alignment rating submissions during an assessment.
#
# Dispatches AssessmentAligned commands through the PersonDevelopment
# command handler. Returns Turbo Stream responses to update the
# frequency selector, scoring panel, and category header.
#
# Either the assessee or their manager can record an alignment — alignment
# is a shared act, not a manager-only one. The aggregate guards that the
# cycle is open via `ensure_in_cycle!`.
#
class Assessments::AlignmentRatingsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/alignment_ratings
  def create
    authorize @assignment, :create_alignment_rating?

    rating_params = params.expect(rating: [ :capability_stable_id, :level_ordinal, :frequency, :comment, :category_id ])
    capability_stable_id = rating_params[:capability_stable_id]
    level_ordinal = Integer(rating_params[:level_ordinal], exception: false)
    unless level_ordinal && FrameworkState::Level.exists?(role_id: @assignment.role_id, ordinal: level_ordinal)
      head :unprocessable_content
      return
    end
    frequency = rating_params[:frequency]
    comment = rating_params[:comment]

    cycle = @assignment.current_open_cycle
    unless cycle
      render_rating_error(capability_stable_id, level_ordinal, "No open assessment cycle")
      return
    end

    handler = PersonDevelopment::CommandHandler.new

    handler.align_assessment(
      @assignment.person_id, @assignment.framework_id, capability_stable_id,
      level_ordinal: level_ordinal, aligned_frequency: frequency,
      cycle_id: cycle.cycle_id, comment: comment
    )

    respond_with_turbo_stream(capability_stable_id, level_ordinal, rating_params[:category_id])
  rescue RuntimeError => e
    render_rating_error(capability_stable_id, level_ordinal, e.message)
  end

  private

  def render_rating_error(capability_stable_id, level_ordinal, message)
    render turbo_stream: turbo_stream.replace(
      "rating-#{capability_stable_id}-#{level_ordinal}",
      render_to_string(
        Views::Assessments::RatingError.new(message: message),
        layout: false
      )
    ), status: :unprocessable_content
  end

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

  def respond_with_turbo_stream(capability_stable_id, level_ordinal, active_category_id = nil)
    framework = FrameworkState::Framework.find_by!(framework_id: @assignment.framework_id)
    role = FrameworkState::Role.find_by!(role_id: @assignment.role_id)
    level = FrameworkState::Level.find_by!(level_id: @assignment.level_id)
    categories = FrameworkState::CapabilityCategory
      .where(framework_id: @assignment.framework_id)
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)

    matrix_data = Assessments::MatrixDataBuilder.new(
      framework: framework, role: role, level: level,
      person_id: @assignment.person_id,
      cycle_id: @assignment.current_open_cycle&.cycle_id,
      categories: categories,
      participant_status: @assignment.current_open_cycle_participant&.status,
      context: :alignment
    ).build

    category_id = find_category_id(capability_stable_id, matrix_data)
    cap_data = find_capability_data(capability_stable_id, matrix_data)
    if cap_data.nil?
      head :not_found
      return
    end

    cell_data = cap_data[:cells][level_ordinal]
    primary = primary_scoring(matrix_data, :alignment)
    blocked = primary.dig(:capability_statuses, capability_stable_id) == :blocked
    block_reason = primary.dig(:block_reasons, capability_stable_id)
    contribution = primary.dig(:capability_contributions, capability_stable_id) || cap_data[:contribution]

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
            context: :alignment,
            category_id: active_category_id || category_id,
            frozen: matrix_data[:individual_ratings_frozen],
            alignment_locked: matrix_data[:alignment_locked]
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "scoring-panel",
        render_to_string(
          Views::Assessments::ScoringPanel.new(
            scoring: matrix_data[:scoring],
            self_scoring: matrix_data[:self_scoring],
            manager_scoring: matrix_data[:manager_scoring],
            aligned_scoring: matrix_data[:aligned_scoring],
            categories: matrix_data[:categories],
            person_level: matrix_data[:person_level],
            mastery_threshold: matrix_data[:mastery_threshold],
            meeting_expectation_threshold: matrix_data[:meeting_expectation_threshold],
            active_category_id: active_category_id || category_id,
            assessment_id: @assignment.id,
            context: :alignment
          ),
          layout: false
        )
      ),
      (turbo_stream.replace(
        "category-indicators-#{category_id}",
        render_to_string(
          Views::Assessments::CategoryIndicators.new(
            category_id: category_id,
            category_result: primary[:category_results]&.dig(category_id),
            secondary_results: secondary_category_results(category_id, matrix_data, :alignment)
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
            secondary_contributions: secondary_capability_contributions(capability_stable_id, matrix_data, :alignment),
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
      ),
      (turbo_stream.replace(
        "category-tabs",
        render_to_string(
          Views::Assessments::CategoryTabs.new(
            categories: matrix_data[:categories],
            scoring: primary,
            self_scoring: matrix_data[:self_scoring],
            manager_scoring: matrix_data[:manager_scoring],
            aligned_scoring: matrix_data[:aligned_scoring],
            active_category_id: active_category_id || category_id,
            assessment_id: @assignment.id,
            context: :alignment
          ),
          layout: false
        )
      ) if active_category_id || category_id)
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

  # Selects the primary scoring perspective, falling back to effective.
  #
  # @param matrix_data [Hash]
  # @param context [Symbol] :self, :manager, or :alignment
  # @return [Hash]
  def primary_scoring(matrix_data, context)
    case context
    when :self      then matrix_data[:self_scoring] || matrix_data[:scoring]
    when :manager   then matrix_data[:manager_scoring] || matrix_data[:scoring]
    when :alignment then matrix_data[:aligned_scoring] || matrix_data[:scoring]
    else matrix_data[:scoring]
    end
  end

  def secondary_scorings(matrix_data, context)
    case context
    when :self
      [ [ "Mgr", matrix_data[:manager_scoring] ], [ "Agreed", matrix_data[:aligned_scoring] ] ]
    when :manager
      [ [ "Self", matrix_data[:self_scoring] ], [ "Agreed", matrix_data[:aligned_scoring] ] ]
    when :alignment
      [ [ "Self", matrix_data[:self_scoring] ], [ "Mgr", matrix_data[:manager_scoring] ] ]
    else []
    end.select { |_, s| s }
  end

  def secondary_category_results(category_id, matrix_data, context)
    secondary_scorings(matrix_data, context).filter_map do |label, scoring|
      result = scoring[:category_results]&.dig(category_id)
      next unless result

      [ label, result ]
    end
  end

  def secondary_capability_contributions(stable_id, matrix_data, context)
    secondary_scorings(matrix_data, context).filter_map do |label, scoring|
      contribution = scoring.dig(:capability_contributions, stable_id)
      next unless contribution

      [ label, contribution ]
    end
  end
end
