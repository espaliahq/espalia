# frozen_string_literal: true

# "How is this calculated?" — the viewer's own arithmetic, then the rules
# (#414).
#
# Opened from the hero and from any category header, and rendered with
# whichever set of components the trigger names, so the same drawer explains
# the whole assessment or one section without two copies of the wording.
#
# The order is deliberate: **their numbers first**, the rules second. A
# person looking at 158% wants to know where 158 came from, not to read a
# definition of scoring and then do the arithmetic themselves. The rules
# below the sum are there for the second read.
#
# Embedded (`standalone: false`) and mounted once on the page root, so the
# trigger can sit inside a Turbo Frame that reloads on every rating without
# taking the open dialog down with it (framework-explorer.md Lesson 19).
class Views::Assessments::ScoreExplainerModal < Views::Base
  include Views::Assessments::Concerns::ScoreScale
  include Views::Assessments::Concerns::DefinedTerms

  ID = "score-explainer-modal"

  # @param components [Hash, nil] `{ prior:, current:, next:, score: }` for
  #   the subject being explained
  # @param state [Symbol, nil]
  # @param subject [String] what the numbers describe ("your score", "Alex's
  #   score", "this section")
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param thresholds [Hash] the framework's own bands
  def initialize(components:, state:, subject:, merged_levels:, person_level:, thresholds: {})
    @components = components
    @state = state
    @subject = subject
    @merged_levels = merged_levels
    @person_level = person_level
    @underperforming_threshold = thresholds[:underperforming]
    @meeting_threshold = thresholds[:meeting]
    @mastery_threshold = thresholds[:mastering]
  end

  def view_template
    render Components::Kit::Modal.new(
      id: ID, title: "How is this calculated?", size: :lg, standalone: false
    ) do |modal|
      modal.body do
        div(class: "space-y-5") do
          arithmetic
          rules
          not_counted
        end
      end
    end
  end

  private

  # The sum, with this person's own numbers in it.
  def arithmetic
    return unless @components

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "#{@subject} today" }
      div(class: "rounded-lg border border-gray-200 dark:border-gray-700 " \
                 "bg-gray-50/50 dark:bg-gray-800/30 p-3 space-y-1") do
        row("Shown at #{current_code}", percent(@components[:current]))
        row("Shown above #{current_code}", percent(@components[:next]), sign: "+") if next_level?
        row("Missing below #{current_code}", percent(1.0 - @components[:prior].to_f), sign: "−") if short_below?
        div(class: "flex items-center justify-between gap-3 pt-2 mt-1 " \
                   "border-t border-gray-200 dark:border-gray-700") do
          span(class: "text-sm font-semibold text-gray-900 dark:text-white") { "Score" }
          span(class: "text-sm font-bold tabular-nums #{tone_text(@state)}") do
            "#{percent(@components[:score])}%"
          end
        end
      end
    end
  end

  def row(label, value, sign: nil)
    div(class: "flex items-center justify-between gap-3") do
      span(class: "text-sm text-gray-700 dark:text-gray-300") { label }
      span(class: "text-sm tabular-nums text-gray-900 dark:text-white") { "#{sign}#{value}%" }
    end
  end

  def short_below?
    @components[:prior].to_f < 1.0
  end

  # The rules, in the order they change the number.
  def rules
    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "How it adds up" }
      ul(class: "space-y-1.5 text-sm text-gray-700 dark:text-gray-300 list-disc pl-5") do
        li { glossary.definition(:score) }
        li { glossary.definition(:below_levels) }
        li { gate_sentence }
        li { glossary.definition(:state) }
      end
    end
  end

  # The one rule people are most surprised by, in plain words.
  def gate_sentence
    return "Anything shown above #{current_code} counts once #{current_code} itself is consistent." unless next_level?

    "What you show at #{next_code} counts in proportion to how consistently you show the same " \
      "capability at #{current_code} — so #{next_code} adds to the number rather than covering " \
      "for #{current_code}."
  end

  def not_counted
    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "What doesn't count" }
      ul(class: "space-y-1.5 text-sm text-gray-700 dark:text-gray-300 list-disc pl-5") do
        li { "Feedback and comments. They are how a rating is discussed and evidenced, never an input to it." }
        li { glossary.definition(:not_rated) }
        li { glossary.definition(:no_expectation) }
      end
    end
  end
end
