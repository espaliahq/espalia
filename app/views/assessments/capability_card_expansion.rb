# frozen_string_literal: true

# Expansion panel below the level strip when a level chip is focused.
#
# Shows expectation text, interactive FrequencySelector (or read-only bar),
# secondary perspective bars, illustrations, evidence, and comments for
# the focused capability × level cell.
#
class Views::Assessments::CapabilityCardExpansion < Views::Base
  # @param cell_data [Hash] from MatrixDataBuilder
  # @param capability [FrameworkState::Capability]
  # @param level [Hash] the focused level from merged_levels
  # @param capability_stable_id [String]
  # @param ordinal [Integer]
  # @param person_level [Integer]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param category_id [String, nil]
  # @param frozen [Boolean]
  # @param alignment_locked [Boolean]
  # @param viewer_person_id [String, nil]
  # @param can_create_evidence [Boolean]
  # @param can_relink_others_evidence [Boolean]
  # @param can_comment [Boolean]
  # @param viewer_is_tenant_admin [Boolean]
  def initialize(cell_data:, capability:, level:, capability_stable_id:,
                 ordinal:, person_level:, assessment_id:, context: :self,
                 category_id: nil, frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false)
    @cell_data = cell_data
    @capability = capability
    @level = level
    @capability_stable_id = capability_stable_id
    @ordinal = ordinal
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
    @category_id = category_id
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
  end

  def view_template
    div(
      id: "expansion-#{@capability_stable_id}",
      class: "mt-3 p-4 rounded-lg border border-gray-200 dark:border-gray-700 " \
             "bg-gray-50/50 dark:bg-gray-800/30"
    ) do
      expansion_header
      expectation_text if @cell_data[:expectation]
      primary_selector
      secondary_bars
      illustrations_section
      evidence_section
      comments_section
    end
  end

  private

  def expansion_header
    div(class: "flex items-center justify-between mb-3") do
      div(class: "flex items-center gap-2") do
        span(class: "text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide") do
          "#{@level[:level_code]} · #{@level[:level_title]}"
        end
      end
      close_button
    end
  end

  def close_button
    button(
      type: "button",
      class: "w-6 h-6 flex items-center justify-center rounded-full " \
             "text-gray-400 hover:text-gray-600 dark:text-gray-500 " \
             "dark:hover:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 " \
             "transition-colors cursor-pointer",
      aria: { label: "Close expansion" },
      data: { action: "click->matrix#unfocusChip" }
    ) { plain "×" }
  end

  def expectation_text
    p(class: "text-sm text-gray-700 dark:text-gray-300 mb-3") do
      @cell_data[:expectation].description
    end
  end

  def primary_selector
    div(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "mb-3") do
      if primary_perspective_frozen?
        render Views::Assessments::FrequencyBar.new(
          label: primary_label,
          frequency: primary_frequency
        )
      else
        render Views::Assessments::FrequencySelector.new(
          capability_stable_id: @capability_stable_id,
          level_ordinal: @ordinal,
          current_frequency: primary_frequency,
          assessment_id: @assessment_id,
          context: @context,
          category_id: @category_id
        )
      end
    end
  end

  def secondary_bars
    bars = secondary_rating_entries
    return if bars.empty?

    div(class: "mb-3 space-y-1") do
      bars.each do |entry|
        render Views::Assessments::FrequencyBar.new(
          label: entry[:label],
          frequency: entry[:frequency],
          primary_frequency: primary_frequency
        )
      end
    end
  end

  def illustrations_section
    illustrations = @cell_data[:illustrations] || []
    return if illustrations.empty?

    div(class: "mb-3") do
      h4(class: "text-[10px] font-semibold text-gray-500 dark:text-gray-400 " \
                "uppercase tracking-wide mb-1") { "Examples" }
      ul(class: "space-y-1") do
        illustrations.each do |ill|
          li(class: "flex items-start gap-1.5 text-xs text-gray-600 dark:text-gray-400") do
            span(class: "mt-1 w-1 h-1 rounded-full bg-gray-400 dark:bg-gray-500 shrink-0") { }
            span { ill.description }
          end
        end
      end
    end
  end

  def evidence_section
    evidence = @cell_data[:evidence] || []
    return unless @viewer_person_id && (evidence.any? || @can_create_evidence)

    div(class: "mb-3") do
      render Views::Assessments::Evidence::List.new(
        items: evidence,
        assessment_id: @assessment_id,
        viewer_person_id: @viewer_person_id,
        can_create: @can_create_evidence,
        can_relink_others: @can_relink_others_evidence,
        capability_stable_id: @capability_stable_id,
        level_ordinal: @ordinal
      )
    end
  end

  def comments_section
    comments = @cell_data[:comments] || []
    return unless @viewer_person_id && (comments.any? || @can_comment)

    render Views::Assessments::Comments::Thread.new(
      comments: comments,
      assessment_id: @assessment_id,
      viewer_person_id: @viewer_person_id,
      can_create: @can_comment,
      tenant_admin: @viewer_is_tenant_admin,
      capability_stable_id: @capability_stable_id,
      level_ordinal: @ordinal
    )
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

  def primary_frequency
    case @context
    when :self      then @cell_data[:current_frequency]
    when :manager   then @cell_data[:manager_frequency]
    when :alignment then @cell_data[:aligned_frequency]
    end
  end

  def secondary_rating_entries
    entries = []
    case @context
    when :self
      entries << { label: "Mgr", frequency: @cell_data[:manager_frequency] }
      entries << { label: "Agreed", frequency: @cell_data[:aligned_frequency] }
    when :manager
      entries << { label: "Self", frequency: @cell_data[:current_frequency] }
      entries << { label: "Agreed", frequency: @cell_data[:aligned_frequency] }
    when :alignment
      entries << { label: "Self", frequency: @cell_data[:current_frequency] }
      entries << { label: "Mgr", frequency: @cell_data[:manager_frequency] }
    end
    entries.select { |e| e[:frequency].present? }
  end
end
