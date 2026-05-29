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
    button(
      id: "cell-#{@capability_stable_id}-#{@ordinal}",
      type: "button",
      class: chip_classes,
      aria: { label: aria_label, pressed: @focused.to_s },
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
    # `appearance-none` strips UA <button> chrome (gradient on macOS,
    # focus outline on Windows). Don't add `bg-transparent` / `text-
    # inherit` here — they're same-specificity utilities that win the
    # cascade against the chip_bg colours we actually want to paint
    # (the class-string still lists bg-green-200 but rgba(0,0,0,0)
    # paints). Tailwind preflight already neutralises the UA button
    # background; the chip_bg utility paints on top.
    base = "appearance-none " \
           "relative flex flex-col items-center justify-center " \
           "h-12 flex-1 min-w-[60px] rounded-lg cursor-pointer " \
           "transition-all border-2 " \
           "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 focus-visible:ring-offset-1 "
    if @focused
      base + "#{chip_bg} #{focus_border} shadow-sm"
    else
      base + "#{chip_bg} #{idle_border} hover:shadow-sm"
    end
  end

  def focus_border
    "border-gray-900 dark:border-white"
  end

  # Unrated idle chips need a quiet but discernible edge so the strip
  # doesn't read as one flat band of colour. Rated chips already carry
  # a solid fill so a transparent border there reads as edge enough.
  def idle_border
    return "border-transparent" if rated?

    "border-gray-200 dark:border-gray-700"
  end

  # Screen-reader label spelling out which capability + level the chip
  # rates, plus the current frequency value (or "unrated"). Without this
  # an SR user just hears "Button — E3" with no context.
  def aria_label
    freq = primary_frequency
    base = at_person_level? ? "Focus #{@level_code} (your level)" : "Focus #{@level_code}"
    rated = freq.present? ? humanise_frequency(freq) : "unrated"
    "#{base}, rated #{rated}"
  end

  def humanise_frequency(freq)
    case freq
    when "consistent" then "consistently"
    when "occasional" then "most times"
    when "some"       then "some times"
    when "none"       then "none"
    else                   freq.to_s
    end
  end

  # Chip background:
  # - unrated below person's level → mint green (assumed-consistent,
  #   since the person is operating at a higher level)
  # - unrated at/above person's level → neutral grey
  # - rated cells → solid colour keyed by frequency
  def chip_bg
    freq = primary_frequency
    if freq.nil?
      @ordinal < @person_level ? "bg-green-100/60 dark:bg-green-900/20" : "bg-gray-100 dark:bg-gray-800"
    else
      case freq
      when "consistent" then "bg-green-200 dark:bg-green-900/40"
      when "occasional" then "bg-amber-200 dark:bg-amber-900/40"
      when "some"       then "bg-red-200 dark:bg-red-900/40"
      when "none"       then "bg-red-100 dark:bg-red-900/20"
      else                   "bg-gray-100 dark:bg-gray-800"
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
