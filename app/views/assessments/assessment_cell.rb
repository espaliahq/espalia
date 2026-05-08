# frozen_string_literal: true

# Unified assessment matrix cell supporting self, manager, and alignment contexts.
#
# Shows the behavioural expectation text, a primary interactive frequency selector,
# 0-2 secondary read-only frequency bars, and an illustration indicator.
#
# The context determines which rating is primary (interactive) and which are
# secondary (read-only bars with divergence indicators).
#
# @example Self-assessment context
#   render Views::Assessments::AssessmentCell.new(
#     cell_data: cell, capability_stable_id: sid, ordinal: 2,
#     person_level: 3, assessment_id: fid, context: :self
#   )
#
class Views::Assessments::AssessmentCell < Views::Base
  # @param cell_data [Hash, nil] from MatrixDataBuilder — nil for empty cells
  # @param capability_id [String, nil] per-version UUID — used by
  #   matrix_controller to wire compact-cell click → focus
  # @param capability_name [String, nil] capability display name —
  #   composed into the cell's accessible focus label
  # @param level_label [String, nil] level title or code — composed
  #   into the cell's accessible focus label; falls back to
  #   "Level <ordinal>" when nil
  # @param capability_stable_id [String]
  # @param ordinal [Integer] the level ordinal for this column
  # @param person_level [Integer] the person's assigned level ordinal
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param category_id [String, nil] active category for tab preservation on rating
  # @param frozen [Boolean] when true and context is :self/:manager, render the
  #   primary frequency as a read-only bar (alignment has been started)
  # @param alignment_locked [Boolean] when true and context is :alignment, render
  #   the primary frequency as a read-only bar (alignment has been completed)
  def initialize(cell_data:, capability_stable_id:, ordinal:, person_level:, assessment_id:, context: :self,
                 capability_id: nil, capability_name: nil, level_label: nil,
                 category_id: nil, frozen: false, alignment_locked: false)
    @cell_data = cell_data
    @capability_id = capability_id
    @capability_name = capability_name
    @level_label = level_label
    @capability_stable_id = capability_stable_id
    @ordinal = ordinal
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
    @category_id = category_id
    @frozen = frozen
    @alignment_locked = alignment_locked
  end

  # Accessible name for the focusable cell control. Includes
  # capability name + level so screen-reader users hear "Focus cell:
  # Critical Thinking · Level 2" rather than the same generic
  # "Focus cell" for every cell in the matrix.
  #
  # @return [String]
  def focus_cell_aria_label
    detail = [
      @capability_name.presence,
      @level_label.presence || "Level #{@ordinal}"
    ].compact
    "Focus cell: #{detail.join(' · ')}"
  end

  def view_template
    if @cell_data.nil?
      empty_cell
    else
      filled_cell
    end
  end

  private

  def empty_cell
    td(class: "px-3 py-2.5 text-center border-b border-r border-gray-100 dark:border-gray-800 " \
              "bg-gray-50/50 dark:bg-gray-800/20 align-top") do
      span(class: "text-gray-300 dark:text-gray-600") { "\u2014" }
    end
  end

  def filled_cell
    # `group/assess-cell` lets descendant components (FrequencySelector,
    # FrequencyBar) respond to this cell's `data-focus-compact` state
    # via Tailwind's `group-data-[focus-compact=true]/assess-cell:*`
    # variants — e.g. wrapping the rating buttons when the column
    # shrinks under cell-focus.
    td(
      id: "cell-#{@capability_stable_id}-#{@ordinal}",
      class: "relative px-3 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 align-top " \
             "min-w-[180px] cursor-pointer group/assess-cell focus:outline-none " \
             "focus-visible:ring-2 focus-visible:ring-primary #{cell_background}",
      tabindex: "0",
      role: "button",
      aria: { label: focus_cell_aria_label },
      data: {
        # `data-level-ordinal` lets matrix_controller#applyColumnFocus
        # find this compact cell when stamping `data-focus-compact` on
        # siblings of the focused column.
        level_ordinal: @ordinal,
        # Compact-cell click (or Enter/Space when keyboard-focused)
        # triggers cell focus AND expands the row. The
        # `focus-on-button-click` flag tells focusCell to NOT bail
        # when the click lands on a rating button — we want both the
        # rating to submit AND the cell to focus.
        action: "click->matrix#focusCell " \
                "keydown.enter->matrix#focusCell " \
                "keydown.space->matrix#focusCell:prevent",
        capability_id: @capability_id,
        capability_stable_id: @capability_stable_id,
        expectation_id: @cell_data.dig(:expectation)&.expectation_id,
        focus_on_button_click: "true"
      }
    ) do
      focus_close_button
      expectation_text
      secondary_bars
      primary_selector
      indicators
    end
  end

  # Close-focus button — top-right of the compact cell. Hidden by
  # default; matrix_controller#applyColumnFocus reveals it inside the
  # focused cell only.
  def focus_close_button
    button(
      type: "button",
      class: "hidden absolute top-1 right-1 z-[3] " \
             "rounded-full bg-white/90 dark:bg-gray-700/90 shadow-sm " \
             "w-6 h-6 items-center justify-center text-gray-500 " \
             "hover:text-gray-900 dark:text-gray-300 dark:hover:text-white " \
             "ring-1 ring-gray-200 dark:ring-gray-600 cursor-pointer text-sm",
      aria: { label: "Exit focus" },
      data: { action: "click->matrix#unfocusCell", focused_cell_close: true }
    ) { plain "×" }
  end

  # Compact-cell footer indicators: illustration count + evidence count.
  # Hidden completely when both are zero so the cell stays dense.
  def indicators
    return if !@cell_data[:illustration_count]&.positive? && !@cell_data[:evidence_count]&.positive?

    div(class: "mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-0.5") do
      illustration_indicator if @cell_data[:illustration_count]&.positive?
      evidence_indicator if @cell_data[:evidence_count]&.positive?
    end
  end

  def expectation_text
    p(class: "text-sm text-gray-700 dark:text-gray-300 line-clamp-3") do
      @cell_data[:expectation].description
    end
  end

  # Interactive frequency selector for the primary rating, OR a read-only
  # frequency bar when alignment has been started for the cycle (self and
  # manager perspectives are frozen until the cycle ends).
  def primary_selector
    div(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "mt-2") do
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

  def primary_perspective_frozen?
    if @context == :alignment
      @alignment_locked
    else
      @frozen
    end
  end

  def primary_label
    case @context
    when :self    then "Self"
    when :manager then "Mgr"
    else "Agreed"
    end
  end

  # Read-only bars for secondary rating perspectives.
  def secondary_bars
    bars = secondary_rating_entries
    return if bars.empty?

    div(class: "mt-1.5") do
      bars.each do |entry|
        render Views::Assessments::FrequencyBar.new(
          label: entry[:label],
          frequency: entry[:frequency],
          primary_frequency: primary_frequency
        )
      end
    end
  end

  # Returns the frequency value for the primary (interactive) context.
  #
  # @return [String, nil]
  def primary_frequency
    case @context
    when :self      then @cell_data[:current_frequency]
    when :manager   then @cell_data[:manager_frequency]
    when :alignment then @cell_data[:aligned_frequency]
    end
  end

  # Returns secondary rating entries to display as read-only bars.
  # Only includes entries that have a frequency value.
  #
  # @return [Array<Hash{label:, frequency:}>]
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

  def illustration_indicator
    div(class: "flex items-center gap-1") do
      span(class: "w-1.5 h-1.5 rounded-full bg-primary") { }
      span(class: "text-[10px] text-gray-400 dark:text-gray-500") do
        count = @cell_data[:illustration_count]
        "#{count} #{'example'.pluralize(count)}"
      end
    end
  end

  def evidence_indicator
    div(class: "flex items-center gap-1") do
      span(class: "w-1.5 h-1.5 rounded-full bg-amber-500") { }
      # "evidence" is treated as uncountable here — matches the card's
      # body copy and avoids "evidences"/"piece of evidence" awkwardness.
      span(class: "text-[10px] text-gray-400 dark:text-gray-500") do
        "#{@cell_data[:evidence_count]} evidence"
      end
    end
  end

  # Cell background color based on the primary context's frequency.
  #
  # @return [String] Tailwind CSS classes
  def cell_background
    freq = primary_frequency
    below = @ordinal < @person_level
    at_or_below = @ordinal <= @person_level

    if freq.nil?
      if below
        "bg-green-100/50 dark:bg-green-800/25"
      else
        "bg-gray-50/50 dark:bg-gray-800/20"
      end
    elsif at_or_below
      case freq
      when "consistent" then "bg-green-100 dark:bg-green-900/30"
      when "occasional" then "bg-amber-100 dark:bg-amber-900/30"
      when "some"       then "bg-red-100 dark:bg-red-900/30"
      when "none"       then "bg-red-50 dark:bg-red-900/20"
      else ""
      end
    else
      case freq
      when "consistent" then "bg-green-100 dark:bg-green-900/30"
      when "none"       then "bg-red-50 dark:bg-red-900/20"
      else "bg-blue-100 dark:bg-blue-900/20"
      end
    end
  end
end
