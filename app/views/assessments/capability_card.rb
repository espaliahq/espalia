# frozen_string_literal: true

# Card-per-capability in the assessment view.
#
# Replaces the old matrix row (AssessmentRow). Each capability is a
# standalone card with a horizontal level strip + optional expansion
# panel for the focused level.
#
class Views::Assessments::CapabilityCard < Views::Base
  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param category [FrameworkState::CapabilityCategory]
  # @param scoring [Hash] primary scoring from MatrixDataBuilder
  # @param blocked [Boolean]
  # @param block_reason [String, nil]
  # @param contribution [Float, nil]
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param focused_level_ordinal [Integer, nil]
  # @param category_id [String, nil]
  # @param frozen [Boolean]
  # @param alignment_locked [Boolean]
  # @param viewer_person_id [String, nil]
  # @param can_create_evidence [Boolean]
  # @param can_relink_others_evidence [Boolean]
  # @param can_comment [Boolean]
  # @param viewer_is_tenant_admin [Boolean]
  def initialize(capability_data:, merged_levels:, person_level:, assessment_id:,
                 context: :self, category: nil, scoring: {},
                 blocked: false, block_reason: nil, contribution: nil,
                 expanded_capability_id: nil, focused_level_ordinal: nil,
                 category_id: nil, frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false)
    @capability_data = capability_data
    @capability = capability_data[:capability]
    @cells = capability_data[:cells]
    @merged_levels = merged_levels
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
    @category = category
    @scoring = scoring
    @blocked = blocked
    @block_reason = block_reason
    @contribution = contribution || capability_data[:contribution]
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin

    @is_expanded = expanded_capability_id == @capability.stable_id
    @focused_ordinal = @is_expanded ? focused_level_ordinal : nil
    @category_id = category_id
  end

  def view_template
    div(
      class: "rounded-xl border border-gray-200 dark:border-gray-700 " \
             "bg-white dark:bg-gray-900 p-4 transition-shadow " \
             "#{@is_expanded ? 'shadow-sm ring-1 ring-primary/10' : 'hover:shadow-sm'}",
      data: {
        matrix_target: "card",
        capability_id: @capability.capability_id,
        capability_stable_id: @capability.stable_id
      }
    ) do
      card_header
      render Views::Assessments::LevelStrip.new(
        cells: @cells,
        merged_levels: @merged_levels,
        capability_stable_id: @capability.stable_id,
        person_level: @person_level,
        context: @context,
        focused_ordinal: active_ordinal
      )
      if @is_expanded && @focused_ordinal
        expansion_panel
      else
        default_rating_area
      end
    end
  end

  private

  def card_header
    div(class: "flex items-start justify-between gap-3 mb-3") do
      div(class: "min-w-0 flex-1") do
        eyebrow
        capability_name
        capability_description if @capability.description.present?
      end
      card_stats
    end
  end

  def eyebrow
    return unless @category

    span(class: "text-[10px] font-medium text-gray-400 dark:text-gray-500 " \
                "uppercase tracking-wider") do
      @category.name
    end
  end

  def capability_name
    div(
      id: "capability-name-#{@capability.stable_id}",
      class: "flex items-center gap-2"
    ) do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white") do
        @capability.name
      end
      blocked_badge if @blocked
      contribution_badge
    end
  end

  def capability_description
    p(class: "text-xs text-gray-500 dark:text-gray-400 mt-0.5 line-clamp-2") do
      @capability.description
    end
  end

  def card_stats
    div(class: "flex items-center gap-3 shrink-0") do
      evidence_button if @can_create_evidence
    end
  end

  def contribution_badge
    return unless @contribution
    return if @contribution.negative?

    pct = (@contribution * 100).round(0)
    color = pct >= 100 ? "text-green-600 dark:text-green-400" :
            pct >= 80  ? "text-amber-600 dark:text-amber-400" :
                         "text-red-600 dark:text-red-400"
    span(class: "text-lg font-bold #{color} ml-auto") { "#{pct}%" }
  end

  def evidence_button
    button(
      type: "button",
      class: "flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400 " \
             "hover:text-gray-700 dark:hover:text-gray-300 " \
             "border border-gray-200 dark:border-gray-700 rounded-md px-2 py-1 " \
             "cursor-pointer transition-colors",
      data: { action: "evidence-form#open",
              evidence_form_capability_stable_id_param: @capability.stable_id,
              evidence_form_level_ordinal_param: @person_level.to_s }
    ) do
      plain "≡ Add evidence"
    end
  end

  def blocked_badge
    span(
      class: "text-[10px] font-medium text-red-600 dark:text-red-400 " \
             "bg-red-50 dark:bg-red-900/20 px-1.5 py-0.5 rounded",
      title: @block_reason
    ) { "Blocked" }
  end

  def active_ordinal
    @focused_ordinal || @person_level
  end

  def default_rating_area
    cell_data = @cells[@person_level]
    return unless cell_data

    level = @merged_levels.find { |l| l[:ordinal] == @person_level }
    return unless level

    div(class: "mt-3 p-3 rounded-lg bg-gray-50/50 dark:bg-gray-800/30") do
      div(class: "flex items-center gap-2 mb-2") do
        span(class: "text-xs text-gray-500 dark:text-gray-400") do
          "#{level[:level_code]} · #{level[:level_title]}"
        end
      end
      p(class: "text-sm text-gray-700 dark:text-gray-300 mb-2") do
        cell_data[:expectation]&.description
      end
      div(id: "rating-#{@capability.stable_id}-#{@person_level}") do
        if primary_perspective_frozen?
          render Views::Assessments::FrequencyBar.new(
            label: primary_label,
            frequency: primary_frequency_for(@person_level)
          )
        else
          render Views::Assessments::FrequencySelector.new(
            capability_stable_id: @capability.stable_id,
            level_ordinal: @person_level,
            current_frequency: primary_frequency_for(@person_level),
            assessment_id: @assessment_id,
            context: @context,
            category_id: @category_id
          )
        end
      end
    end
  end

  def primary_perspective_frozen?
    @context == :alignment ? @alignment_locked : @frozen
  end

  def primary_label
    case @context
    when :self    then "Self"
    when :manager then "Mgr"
    else "Agreed"
    end
  end

  def primary_frequency_for(ordinal)
    cell = @cells[ordinal]
    return nil unless cell

    case @context
    when :self      then cell[:current_frequency]
    when :manager   then cell[:manager_frequency]
    when :alignment then cell[:aligned_frequency]
    end
  end

  def expansion_panel
    focused_level = @merged_levels.find { |l| l[:ordinal] == @focused_ordinal }
    cell_data = @cells[@focused_ordinal]
    return unless cell_data && focused_level

    render Views::Assessments::CapabilityCardExpansion.new(
      cell_data: cell_data,
      capability: @capability,
      level: focused_level,
      capability_stable_id: @capability.stable_id,
      ordinal: @focused_ordinal,
      person_level: @person_level,
      assessment_id: @assessment_id,
      context: @context,
      category_id: @category_id,
      frozen: @frozen,
      alignment_locked: @alignment_locked,
      viewer_person_id: @viewer_person_id,
      can_create_evidence: @can_create_evidence,
      can_relink_others_evidence: @can_relink_others_evidence,
      can_comment: @can_comment,
      viewer_is_tenant_admin: @viewer_is_tenant_admin
    )
  end
end
