# frozen_string_literal: true

# The one vocabulary for the level-independent score (ADR-21) at every
# altitude — the hero, a category header, a capability card, the chip bar.
#
# Three things every scored surface needs and must agree on:
#
# - **Tone by state.** The number and the bar take their colour from the
#   performance STATE, never from the raw score, so a 150% held at
#   "progressing" by a blocked capability reads amber like its verdict.
#   Deliberately not the frequency palette — red/yellow/green/blue there
#   means *ratings*; here green/purple mean *verdicts*.
# - **The state words**, one label per state — read through
#   {Views::Assessments::StateLabels}, since a tenant can rename them.
# - **Level codes** relative to the assessed level, read off the merged
#   levels the engine also scores against (both come from the role's
#   ladder), so a gap in the ordinals cannot make copy and number disagree.
#
# Mix into a view that holds `@merged_levels` and `@person_level`.
module Views::Assessments::Concerns::ScoreScale
  TONE_TEXT = {
    red: "text-red-700 dark:text-red-400",
    amber: "text-amber-700 dark:text-amber-400",
    green: "text-green-700 dark:text-green-400",
    purple: "text-purple-600 dark:text-purple-400"
  }.freeze
  TONE_BAR = { red: "bg-red-500", amber: "bg-amber-500", green: "bg-green-500", purple: "bg-purple-500" }.freeze
  TONE_DOT = TONE_BAR

  # @param state [Symbol, nil] a `performance_state` symbol
  # @return [Symbol] :red | :amber | :green | :purple
  def tone_for(state)
    case state
    when :eligible, :mastering then :purple
    when :performing, :top_of_ladder then :green
    when :progressing then :amber
    else :red
    end
  end

  def tone_text(state) = TONE_TEXT.fetch(tone_for(state))
  def tone_bar(state) = TONE_BAR.fetch(tone_for(state))

  # The word this tenant uses for the state — not a constant here, because
  # a tenant can rename it (#415). {Views::Assessments::StateLabels} is the
  # one reader, so every altitude says the same thing.
  #
  # @param state [Symbol, nil]
  # @return [String]
  def state_label(state)
    Views::Assessments::StateLabels.for(state)
  end

  # @param value [Numeric, nil] a 0.0–N ratio
  # @return [Integer] whole percent
  def percent(value)
    (value.to_f * 100).round(0)
  end

  # ── Level codes ──

  def level_code(ordinal)
    @merged_levels.find { |l| l[:ordinal] == ordinal }&.dig(:level_code)
  end

  def current_code
    @current_code ||= level_code(@person_level) || "L#{@person_level}"
  end

  # The merged levels above the assessed one, in ladder order.
  def levels_above
    @levels_above ||= @merged_levels.select { |l| l[:ordinal] > @person_level }.sort_by { |l| l[:ordinal] }
  end

  def next_code
    levels_above.first&.dig(:level_code)
  end

  # The code of the level `index` steps above the assessed one.
  def code_above(index)
    levels_above[index]&.dig(:level_code) || "+#{index + 1}"
  end

  def next_level?
    levels_above.any?
  end

  # How many bands the bar runs through above the assessed level — the
  # engine's `bands_above` (the ladder above, windowed by the cap), never
  # more levels than the ladder has.
  #
  # @param components [Hash, nil] a components hash carrying :bands_above
  # @return [Integer]
  def bands_for(components)
    return 0 unless next_level?

    (components&.dig(:bands_above) || 1).to_i.clamp(1, levels_above.size)
  end

  # "38% of the way to E4" — the next-band component as level-by-level
  # copy. With the default cap it is one phrase; with a wider cap a whole
  # band reads "E4 demonstrated in full" and the remainder names the level
  # after.
  #
  # @param components [Hash, nil]
  # @return [Array<String>]
  def next_band_phrases(components)
    nxt = components&.dig(:next).to_f
    whole = [ nxt.floor, levels_above.size ].min
    phrases = whole.positive? ? [ "#{code_above(whole - 1)} demonstrated in full" ] : []
    remainder = nxt - whole
    if levels_above[whole] && (remainder.positive? || phrases.empty?)
      phrases << "#{percent(remainder)}% of the way to #{code_above(whole)}"
    end
    phrases
  end
end
