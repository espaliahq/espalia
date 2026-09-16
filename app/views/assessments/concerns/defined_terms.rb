# frozen_string_literal: true

# Renders a scored term with its own definition attached (#414).
#
# Mixed into any assessment view that already carries `@merged_levels` and
# `@person_level` (the ScoreScale contract) plus the matrix data's
# thresholds. The glossary is built once per view from those, so every
# definition names this viewer's level codes, their framework's configured
# bands, and their tenant's word for a state.
#
# `Components::Kit::DefinitionTip` does the work — hover AND keyboard, never
# hover-only, and never the native `title` attribute, which no keyboard user
# can reach. That matters more here than on the calibration screens: the
# person reading these numbers is the person they are about.
module Views::Assessments::Concerns::DefinedTerms
  # Every assessment term overrides the tip's default look, because each
  # already has a visual form of its own — a big number, a badge, a muted
  # count. Two things they must not lose with it:
  #
  # - `inline-flex items-center`, or the ⓘ glyph wraps onto its own line
  #   under the term. It did, in a compact category header.
  # - a 24px tap target (WCAG 2.2 AA, 2.5.8). The Kit default is the
  #   house 44px, which doubles the height of an 11px indicator row — so
  #   these controls take the floor rather than the preference, and the
  #   surrounding row keeps its shape.
  COMPACT_TRIGGER = "inline-flex items-center min-h-6"

  # @return [Views::Assessments::Glossary]
  def glossary
    @glossary ||= Views::Assessments::Glossary.new(
      current_code: current_code,
      next_code: next_code,
      thresholds: glossary_thresholds,
      second_person: glossary_second_person?
    )
  end

  # Renders the term with its definition attached.
  #
  # @param key [Symbol] a glossary key
  # @param label [String, nil] override the displayed text — the definition
  #   is unchanged (a number, a badge, a count; the word is the subject)
  # @param suffix [String, nil] REQUIRED wherever a term repeats on one page.
  #   The id wires `aria-describedby`, so a duplicate makes every one of them
  #   ambiguous — pass the row's stable id.
  # @param align [Symbol] :left or :right — flip near a viewport edge
  # @param trigger_class [String, nil] for a term that already has a visual
  #   form of its own (a coloured percentage, a badge)
  def defined_term(key, label: nil, suffix: nil, align: :left, trigger_class: nil)
    render Components::Kit::DefinitionTip.new(
      label || glossary.label(key),
      definition: glossary.definition(key),
      id: [ "assessment-term", key.to_s.tr("_", "-"), suffix ].compact.join("-"),
      align: align,
      trigger_class: trigger_class && "#{COMPACT_TRIGGER} #{trigger_class}"
    )
  end

  # Whether the reader is the person being described. Views that render
  # for a manager set `@context` to something other than `:self`; anything
  # without a context is the assessee's own page.
  #
  # @return [Boolean]
  def glossary_second_person?
    !defined?(@context) || @context.nil? || @context == :self
  end

  # The framework's own bands. Falls back to the engine's defaults only when
  # a caller has no matrix data to hand — never to a hard-coded 80/95/150 in
  # the copy itself.
  #
  # @return [Hash]
  def glossary_thresholds
    {
      underperforming: @underperforming_threshold ||
        PersonDevelopment::Scoring::DEFAULT_UNDERPERFORMING_THRESHOLD,
      meeting: @meeting_threshold ||
        PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD,
      mastering: @mastery_threshold ||
        PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD
    }
  end
end
