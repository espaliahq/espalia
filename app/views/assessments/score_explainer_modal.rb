# frozen_string_literal: true

# "How is this calculated?" — the viewer's own arithmetic, then the rules
# (#414).
#
# Their numbers first, the rules second: a person looking at 158% wants to
# know where 158 came from, not to read a definition and do the sum.
#
# Mounted once on the page root (`standalone: false`) so the trigger can sit
# inside a Turbo Frame that reloads on every rating without taking the open
# dialog down with it (framework-explorer.md Lesson 19). Nothing else
# replaces it, which is why each rating streams it — see
# `Assessments::TurboStreamHelpers`.
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
  # @param second_person [Boolean] whether the reader is the person these
  #   numbers describe — a manager must not read "what E3 expects you show"
  # @param thresholds [Hash] the framework's own bands
  # @param emphasised [Array<Hash>] the capabilities that count differently
  #   for this role — `{ stable_id:, name:, weight:, required: }`, from
  #   `.emphasised_from`
  def initialize(components:, state:, subject:, merged_levels:, person_level:, thresholds: {},
                 second_person: true, emphasised: [])
    @components = components
    @emphasised = emphasised
    @state = state
    @subject = subject
    @merged_levels = merged_levels
    @person_level = person_level
    @underperforming_threshold = thresholds[:underperforming]
    @meeting_threshold = thresholds[:meeting]
    @mastery_threshold = thresholds[:mastering]
    @second_person = second_person
  end

  # The capabilities whose binding changes how a rating lands — a weight
  # other than 1, or a tolerance of 0 — read off the matrix data every
  # render site already holds, so the drawer names them rather than
  # defining "weight" for a list the reader cannot see (#431).
  #
  # @param matrix_data [Hash] from `Assessments::MatrixDataBuilder#build`
  # @return [Array<Hash>]
  def self.emphasised_from(matrix_data)
    matrix_data[:categories].flat_map { |c| c[:capabilities] }.filter_map do |cap|
      weighted = cap[:weight].present? && cap[:weight].to_f != 1.0
      next unless weighted || cap[:required]

      { stable_id: cap[:capability].stable_id, name: cap[:capability].name,
        weight: cap[:weight], required: cap[:required] || false }
    end
  end

  def view_template
    render Components::Kit::Modal.new(
      id: ID, title: "How is this calculated?", size: :lg, standalone: false
    ) do |modal|
      modal.body do
        div(class: "space-y-5") do
          arithmetic
          counts_differently
          rules
          not_counted
        end
      end
    end
  end

  private

  # Their own list first, the rule second — the same order as the
  # arithmetic above it. The chips are the ones the cards wear, so the
  # drawer and the page use one vocabulary.
  def counts_differently
    return if @emphasised.empty?

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "Counts differently for this role" }
      ul(class: "space-y-1 text-sm text-gray-700 dark:text-gray-300") do
        @emphasised.each do |cap|
          li(class: "flex flex-wrap items-center gap-x-2 gap-y-1") do
            span { cap[:name] }
            weight_chip(cap[:weight], suffix: "explainer-#{cap[:stable_id]}")
            required_chip(cap[:required], suffix: "explainer-#{cap[:stable_id]}")
          end
        end
      end
    end
  end

  # The concern guesses from `@context`; this view is handed the answer.
  def glossary_second_person? = @second_person

  def arithmetic
    return unless @components

    parts = displayed_parts
    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "#{@subject} today" }
      div(class: "rounded-lg border border-gray-200 dark:border-gray-700 " \
                 "bg-gray-50/50 dark:bg-gray-800/30 p-3 space-y-1") do
        row("Shown at #{current_code}", parts[:current])
        row("Shown above #{current_code}", parts[:next], sign: "+") if next_level?
        row("Missing below #{current_code}", parts[:missing], sign: "−") if short_below?
        div(class: "flex items-center justify-between gap-3 pt-2 mt-1 " \
                   "border-t border-gray-200 dark:border-gray-700") do
          span(class: "text-sm font-semibold text-gray-900 dark:text-white") { "Score" }
          span(class: "text-sm font-bold tabular-nums #{tone_text(@state)}") do
            "#{parts[:score]}%"
          end
        end
      end
    end
  end

  # Rounded on their own, the rows can fail to add up to the total — 11% +
  # 11% under a score of 23%. The score is authoritative (the hero renders
  # the same number), so the residual goes to the largest part.
  def displayed_parts
    current = percent(@components[:current])
    nxt     = next_level? ? percent(@components[:next]) : 0
    missing = short_below? ? percent(1.0 - @components[:prior].to_f) : 0
    score   = percent(@components[:score])

    residual = score - (current + nxt - missing)
    if residual != 0
      if nxt >= current
        nxt += residual
      else
        current += residual
      end
    end

    { current: current, next: nxt, missing: missing, score: score }
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

  def rules
    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "How it adds up" }
      ul(class: "space-y-1.5 text-sm text-gray-700 dark:text-gray-300 list-disc pl-5") do
        li { glossary.definition(:score) }
        li { glossary.definition(:below_levels) }
        li { gate_sentence }
        li { glossary.definition(:weight) }
        li { glossary.definition(:required) }
        li { glossary.definition(:carried) }
        li { glossary.definition(:state) }
      end
    end
  end

  def gate_sentence
    # At the top of the ladder there is nothing above to earn credit at, so
    # the gate has nothing to gate — describing it would promise a band the
    # person can never reach.
    unless next_level?
      return "#{current_code} is the top of the ladder. The number says how much of it is shown; " \
             "there is no level above to earn more."
    end

    who = @second_person ? "you" : "they"
    "What #{who} show at #{next_code} counts in proportion to how consistently #{who} show the " \
      "same capability at #{current_code}. #{next_code} adds to the number; it does not cover " \
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
