# frozen_string_literal: true

# Handles self-rating submissions during an assessment.
#
# Dispatches through {Operations::Assessments::RateSelf} — the same code
# path as the MCP tool, so the cell check (the level is the lens role's and
# the role reads the cell) and the toggle semantics can't drift between
# them. Returns Turbo Stream responses to update the frequency selector,
# scoring panel, and category header, re-rendered against the lens the page
# is read through (`as_role` / `as_level`, forwarded by the pill's form).
#
class Assessments::RatingsController < ApplicationController
  include Assessments::TurboStreamHelpers
  include AssessmentVisibility

  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/ratings
  def create
    authorize @assignment, :create_self_rating?
    # Resolve the page's lens before writing: a stale or crafted one is a
    # 404 that has changed nothing, not a saved rating with no response.
    response_lens

    rating_params = params.expect(rating: [ :capability_stable_id, :level_ordinal, :frequency, :comment, :category_id, :clear, :confirm ])
    capability_stable_id = rating_params[:capability_stable_id]
    level_ordinal = Integer(rating_params[:level_ordinal], exception: false)

    operation = Operations::Assessments::RateSelf.new(context: pundit_user, params: {
      assignment_id: @assignment.id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      frequency: rating_params[:frequency],
      comment: rating_params[:comment],
      rationale: "Updated during self-assessment",
      clear: rating_params[:clear].presence,
      confirm: rating_params[:confirm].presence,
      as_role_id: params[:as_role].presence
    })
    begin
      operation.call
    rescue Pundit::NotAuthorizedError => e
      # The Operation's own refusal (a cell the record doesn't read) carries
      # a reason; a bodyless 403 would leave the click doing nothing on screen.
      return render_rating_error(capability_stable_id, level_ordinal, e.message, status: :forbidden)
    end

    respond_with_turbo_stream(capability_stable_id, level_ordinal, rating_params[:category_id],
      announce: operation.changed?)
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_rating_error(capability_stable_id, level_ordinal, e.message)
  end

  private

  def render_rating_error(capability_stable_id, level_ordinal, message, status: :unprocessable_content)
    render turbo_stream: turbo_stream.replace(
      "rating-#{capability_stable_id}-#{level_ordinal}",
      render_to_string(
        Views::Assessments::RatingError.new(message: message),
        layout: false
      )
    ), status: status
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

  def respond_with_turbo_stream(capability_stable_id, level_ordinal, active_category_id = nil, announce: true)
    # Reload fresh data for the turbo stream response, read through the
    # page's lens so the re-rendered fragments match the page around them.
    matrix_data = Assessments::MatrixDataBuilder.for_lens(
      lens: response_lens,
      context: :self,
      viewer_person_id: current_person&.id,
      viewer_sees_all_evidence: viewer_sees_all_evidence?
    )

    # Find the capability's category for targeted category header update
    category_id = find_category_id(capability_stable_id, matrix_data)

    # Find capability data (cell, contribution, binding, etc.) for targeted updates
    cap_data = find_capability_data(capability_stable_id, matrix_data)
    if cap_data.nil?
      head :not_found
      return
    end
    cell_data = cap_data[:cells][level_ordinal]
    level_code = matrix_data[:merged_levels].find { |l| l[:ordinal] == level_ordinal }&.dig(:level_code) || "L#{level_ordinal}"
    primary = primary_scoring(matrix_data, :self)

    render turbo_stream: [
      (live_status_stream(cap_data: cap_data, cell_data: cell_data, level_code: level_code,
        frequency: cell_data&.dig(:current_frequency)) if announce),
      (turbo_stream.replace(
        Views::Assessments::StatusPill::WRAPPER_ID,
        render_to_string(
          Views::Assessments::StatusPill.new(
            participant_status: matrix_data[:participant_status],
            has_open_cycle: @assignment.current_open_cycle.present?,
            current_level_complete: matrix_data[:current_level_complete],
            work: matrix_data[:current_level_work]
          ),
          layout: false
        )
      ) if response_lens.home?),
      turbo_stream.replace(
        "cell-#{capability_stable_id}-#{level_ordinal}",
        render_to_string(
          Views::Assessments::LevelChip.new(
            cell_data: cell_data,
            capability_stable_id: capability_stable_id,
            ordinal: level_ordinal,
            person_level: matrix_data[:person_level],
            level_code: level_code,
            context: :self,
            focused: true,
            **lens_chip_options(matrix_data)
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "rating-#{capability_stable_id}-#{level_ordinal}",
        rating_wrapper_html(capability_stable_id, level_ordinal, cell_data&.dig(:current_frequency),
                            :self, active_category_id || category_id,
                            carried: cell_data&.dig(:current_frequency_carried) || false)
      ),
      turbo_stream.replace(
        "secondaries-#{capability_stable_id}-#{level_ordinal}",
        secondaries_wrapper_html(capability_stable_id, level_ordinal, cell_data,
                                 cell_data&.dig(:current_frequency), :self)
      ),
      turbo_stream.replace(
        "scoring-panel",
        render_to_string(
          Views::Assessments::HeroSummary.new(
            scoring: matrix_data[:scoring],
            self_scoring: matrix_data[:self_scoring],
            manager_scoring: matrix_data[:manager_scoring],
            aligned_scoring: matrix_data[:aligned_scoring],
            thresholds: Views::Assessments::Glossary.thresholds_from(matrix_data),
            categories: matrix_data[:categories],
            person_level: matrix_data[:person_level],
            merged_levels: matrix_data[:merged_levels],
            assessment_id: @assignment.id,
            context: :self,
            lens: matrix_data[:lens],
            ratings_frozen: matrix_data[:individual_ratings_frozen]
          ),
          layout: false
        )
      ),
      (turbo_stream.replace(
        "category-indicators-#{category_id}",
        render_to_string(
          Views::Assessments::CategoryIndicators.new(
            category_id: category_id,
            category_score: primary.dig(:category_scores, category_id),
            secondary_scores: secondary_category_scores(category_id, matrix_data, :self),
            category_data: matrix_data[:categories].find { |c| c[:category].category_id == category_id },
            context: :self,
            merged_levels: matrix_data[:merged_levels],
            person_level: matrix_data[:person_level],
            thresholds: Views::Assessments::Glossary.thresholds_from(matrix_data),
            viewer_is_manager: viewer_is_manager?,
            confirm_href: (assessment_carried_ratings_path(@assignment, category_id: category_id) if response_lens.home?)
          ),
          layout: false
        )
      ) if category_id),
      turbo_stream.replace(
        "capability-name-#{capability_stable_id}",
        capability_name_html(cap_data, matrix_data, primary, :self)
      ),
      score_explainer_stream(matrix_data, primary, :self),
      (turbo_stream.replace(
        "category-tabs",
        render_to_string(
          Views::Assessments::CategoryChipBar.new(
            categories: matrix_data[:categories],
            scoring: primary,
            active_category_id: active_category_id || category_id,
            context: :self
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

  def secondary_category_scores(category_id, matrix_data, context)
    Assessments::SecondaryPerspectives.category_scores(matrix_data, context, category_id)
  end
end
