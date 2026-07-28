# frozen_string_literal: true

# Handles manager rating submissions during an assessment.
#
# Dispatches ManagerRated / ManagerRatingRevised commands through the
# PersonDevelopment command handler. Returns Turbo Stream responses
# to update the frequency selector, scoring panel, and category header.
#
# The key difference from {Assessments::RatingsController} is that the
# assessee is resolved from the URL (not current_person), and authorization
# checks that current_person is the assessee's manager.
#
class Assessments::ManagerRatingsController < ApplicationController
  include Assessments::TurboStreamHelpers
  include AssessmentVisibility

  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/manager_ratings
  def create
    authorize @assignment, :create_manager_rating?

    rating_params = params.expect(rating: [ :capability_stable_id, :level_ordinal, :frequency, :comment, :category_id, :clear ])
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

    existing = AssessmentLevelRating.find_by(
      cycle_id: cycle.cycle_id,
      person_id: @assignment.person_id,
      framework_id: @assignment.framework_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal
    )

    if rating_params[:clear].present?
      # Explicit clear-or-noop — see Assessments::RatingsController.
      if existing&.manager_rated_frequency.present?
        handler.clear_manager_rating(
          @assignment.person_id, @assignment.framework_id, capability_stable_id,
          level_ordinal: level_ordinal, cycle_id: cycle.cycle_id, rated_by_id: current_person.id
        )
      end
    elsif existing&.manager_rated_frequency == frequency && existing&.manager_rating_carried?
      # Confirming a carried-forward (seeded) value — re-emit as a human
      # rating (provenance flips, carried treatment solidifies); untoggle-
      # to-clear only applies to ratings the manager made themselves.
      handler.revise_manager_rating(
        @assignment.person_id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal, frequency: frequency,
        rationale: "Confirmed carried-forward rating", cycle_id: cycle.cycle_id, comment: comment,
        rated_by_id: current_person.id
      )
    elsif existing&.manager_rated_frequency == frequency
      # Untoggle: clicking the already-selected frequency clears the rating
      handler.clear_manager_rating(
        @assignment.person_id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal, cycle_id: cycle.cycle_id, rated_by_id: current_person.id
      )
    elsif existing&.manager_rated_frequency.present?
      handler.revise_manager_rating(
        @assignment.person_id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal, frequency: frequency,
        rationale: "Updated during manager assessment", cycle_id: cycle.cycle_id, comment: comment,
        rated_by_id: current_person.id
      )
    else
      handler.rate_as_manager(
        @assignment.person_id, @assignment.framework_id, capability_stable_id,
        level_ordinal: level_ordinal, frequency: frequency,
        cycle_id: cycle.cycle_id, comment: comment, rated_by_id: current_person.id
      )
    end

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
      .where(framework_id: @assignment.framework_id, status: "active")
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)

    matrix_data = Assessments::MatrixDataBuilder.new(
      framework: framework, role: role, level: level,
      person_id: @assignment.person_id,
      cycle_id: @assignment.current_open_cycle&.cycle_id,
      categories: categories,
      participant_status: @assignment.current_open_cycle_participation&.status,
      context: :manager,
      viewer_person_id: current_person&.id,
      viewer_sees_all_evidence: viewer_sees_all_evidence?
    ).build

    category_id = find_category_id(capability_stable_id, matrix_data)
    cap_data = find_capability_data(capability_stable_id, matrix_data)
    if cap_data.nil?
      head :not_found
      return
    end

    cell_data = cap_data[:cells][level_ordinal]
    level_code = matrix_data[:merged_levels].find { |l| l[:ordinal] == level_ordinal }&.dig(:level_code) || "L#{level_ordinal}"
    primary = primary_scoring(matrix_data, :manager)
    blocked = primary.dig(:capability_statuses, capability_stable_id) == :blocked
    block_reason = primary.dig(:block_reasons, capability_stable_id)
    contribution = primary.dig(:capability_contributions, capability_stable_id) || cap_data[:contribution]

    render turbo_stream: [
      turbo_stream.replace(
        Views::Assessments::StatusPill::WRAPPER_ID,
        render_to_string(
          Views::Assessments::StatusPill.new(
            participant_status: matrix_data[:participant_status],
            has_open_cycle: @assignment.current_open_cycle.present?,
            current_level_complete: matrix_data[:current_level_complete]
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "cell-#{capability_stable_id}-#{level_ordinal}",
        render_to_string(
          Views::Assessments::LevelChip.new(
            cell_data: cell_data,
            capability_stable_id: capability_stable_id,
            ordinal: level_ordinal,
            person_level: matrix_data[:person_level],
            level_code: level_code,
            context: :manager,
            focused: true
          ),
          layout: false
        )
      ),
      turbo_stream.replace(
        "rating-#{capability_stable_id}-#{level_ordinal}",
        rating_wrapper_html(capability_stable_id, level_ordinal, cell_data&.dig(:manager_frequency),
                            :manager, active_category_id || category_id,
                            carried: cell_data&.dig(:manager_frequency_carried) || false)
      ),
      turbo_stream.replace(
        "secondaries-#{capability_stable_id}-#{level_ordinal}",
        secondaries_wrapper_html(capability_stable_id, level_ordinal, cell_data,
                                 cell_data&.dig(:manager_frequency), :manager)
      ),
      turbo_stream.replace(
        "scoring-panel",
        render_to_string(
          Views::Assessments::HeroSummary.new(
            scoring: matrix_data[:scoring],
            self_scoring: matrix_data[:self_scoring],
            manager_scoring: matrix_data[:manager_scoring],
            aligned_scoring: matrix_data[:aligned_scoring],
            categories: matrix_data[:categories],
            person_level: matrix_data[:person_level],
            merged_levels: matrix_data[:merged_levels],
            mastery_threshold: matrix_data[:mastery_threshold],
            meeting_expectation_threshold: matrix_data[:meeting_expectation_threshold],
            assessment_id: @assignment.id,
            context: :manager,
            assessee_name: assessee_name
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
            secondary_results: secondary_category_results(category_id, matrix_data, :manager),
            category_data: matrix_data[:categories].find { |c| c[:category].category_id == category_id },
            context: :manager
          ),
          layout: false
        )
      ) if category_id),
      turbo_stream.replace(
        "capability-name-#{capability_stable_id}",
        capability_name_html(cap_data, blocked, block_reason, contribution)
      ),
      (turbo_stream.replace(
        "category-tabs",
        render_to_string(
          Views::Assessments::CategoryChipBar.new(
            categories: matrix_data[:categories],
            scoring: primary,
            active_category_id: active_category_id || category_id,
            context: :manager
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

  def assessee_name
    @assessee_name ||= Person.find_by(id: @assignment.person_id)&.name
  end
end
