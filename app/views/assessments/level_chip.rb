# frozen_string_literal: true

# Single level chip in the horizontal assessment level strip.
#
# Colored by frequency × level position, carrying the Turbo Stream
# target ID `cell-<stable_id>-<ordinal>` so rating controller
# responses can replace individual chips in-place.
#
class Views::Assessments::LevelChip < Views::Base
  # @param cell_data [Hash, nil] from MatrixDataBuilder
  # @param capability_stable_id [String]
  # @param ordinal [Integer]
  # @param person_level [Integer]
  # @param level_code [String] compact label (e.g. "E7")
  # @param context [Symbol] :self, :manager, or :alignment
  # @param focused [Boolean] whether this chip is the currently focused level
  def initialize(cell_data:, capability_stable_id:, ordinal:, person_level:,
                 level_code:, context: :self, focused: false)
    @cell_data = cell_data
    @capability_stable_id = capability_stable_id
    @ordinal = ordinal
    @person_level = person_level
    @level_code = level_code
    @context = context
    @focused = focused
  end

  def view_template
    div(
      id: "cell-#{@capability_stable_id}-#{@ordinal}",
      class: chip_classes,
      data: {
        level_ordinal: @ordinal,
        action: "click->matrix#focusChip",
        capability_stable_id: @capability_stable_id
      }
    ) do
      span(class: "text-xs font-medium relative z-[1]") { @level_code }
      you_badge if at_person_level?
      rated_check if rated?
      divergence_dot if divergent?
    end
  end

  private

  def chip_classes
    base = "relative flex flex-col items-center justify-center " \
           "h-12 flex-1 min-w-[60px] rounded-lg cursor-pointer " \
           "transition-all border-2 "
    if @focused
      base + "#{chip_bg} #{focus_border} shadow-sm"
    else
      base + "#{chip_bg} border-transparent hover:shadow-sm"
    end
  end

  def focus_border
    "border-gray-900 dark:border-white"
  end

  def chip_bg
    freq = primary_frequency
    below = @ordinal < @person_level
    at_or_below = @ordinal <= @person_level

    if freq.nil?
      below ? "bg-green-100/60 dark:bg-green-900/20" : "bg-gray-100 dark:bg-gray-800"
    elsif at_or_below
      case freq
      when "consistent" then "bg-green-200 dark:bg-green-900/40"
      when "occasional" then "bg-amber-200 dark:bg-amber-900/40"
      when "some"       then "bg-red-200 dark:bg-red-900/40"
      when "none"       then "bg-red-100 dark:bg-red-900/20"
      else "bg-gray-100 dark:bg-gray-800"
      end
    else
      case freq
      when "consistent" then "bg-green-200 dark:bg-green-900/40"
      when "none"       then "bg-red-100 dark:bg-red-900/20"
      else "bg-blue-100 dark:bg-blue-900/20"
      end
    end
  end

  def primary_frequency
    return nil unless @cell_data

    case @context
    when :self      then @cell_data[:current_frequency]
    when :manager   then @cell_data[:manager_frequency]
    when :alignment then @cell_data[:aligned_frequency]
    end
  end

  def at_person_level?
    @ordinal == @person_level
  end

  def rated?
    primary_frequency.present?
  end

  def divergent?
    return false unless @cell_data

    pf = primary_frequency
    return false unless pf

    secondaries = secondary_frequencies
    secondaries.any? { |f| f.present? && f != pf }
  end

  def secondary_frequencies
    return [] unless @cell_data

    case @context
    when :self
      [ @cell_data[:manager_frequency], @cell_data[:aligned_frequency] ]
    when :manager
      [ @cell_data[:current_frequency], @cell_data[:aligned_frequency] ]
    when :alignment
      [ @cell_data[:current_frequency], @cell_data[:manager_frequency] ]
    end.compact
  end

  def you_badge
    span(class: "absolute -bottom-0.5 left-1/2 -translate-x-1/2 " \
                "text-[9px] font-bold uppercase tracking-wider " \
                "bg-gray-800 dark:bg-white text-white dark:text-gray-900 " \
                "px-1.5 py-px rounded-sm") { "YOU" }
  end

  def rated_check
    span(class: "absolute top-0.5 right-0.5 w-3 h-3 flex items-center justify-center") do
      span(class: "text-[8px] text-green-700 dark:text-green-400") { "✓" }
    end
  end

  def divergence_dot
    span(
      class: "absolute top-0.5 left-0.5 w-2 h-2 rounded-full bg-amber-400 dark:bg-amber-500",
      title: "Perspectives differ"
    ) { }
  end
end
