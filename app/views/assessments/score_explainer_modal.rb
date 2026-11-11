# frozen_string_literal: true

# "How is this calculated?" — the viewer's own arithmetic, then the rules
# (#414).
#
# Their numbers first, the rules second: a person looking at 158% wants to
# know where 158 came from, not to read a definition and do the sum.
#
# Mounted once on the page root (`standalone: false`) so the trigger can sit
# inside a Turbo Frame that reloads on every rating without taking the open
# dialog down with it (framework-explorer.md Lesson 19). Only its content
# frame ever changes: the viewer's own rating streams into it
# (`Assessments::TurboStreamHelpers`), and someone else's makes
# `assessment_sync_controller` reload it from `GET /assessments/:id/score_explainer`.
class Views::Assessments::ScoreExplainerModal < Views::Base
  include Views::Assessments::Concerns::ScoreScale
  include Views::Assessments::Concerns::DefinedTerms

  register_element :turbo_frame

  ID = "score-explainer-modal"
  CONTENT_ID = "score-explainer-content"

  # The drawer for the perspective a page, a rating stream or a reload is showing.
  #
  # @param matrix_data [Hash] `Assessments::MatrixDataBuilder#build`
  # @param scoring [Hash] the perspective the hero renders
  # @param subject [String] see {#initialize}
  # @param second_person [Boolean] see {#initialize}
  # @param part [Symbol] see {#initialize}
  # @param src [String, nil] where the content frame reloads from
  # @return [Views::Assessments::ScoreExplainerModal]
  def self.for(matrix_data:, scoring:, subject:, second_person:, part: :modal, src: nil)
    new(
      components: scoring&.dig(:components), state: scoring&.dig(:performance_state), subject: subject,
      merged_levels: matrix_data[:merged_levels], person_level: matrix_data[:person_level],
      thresholds: Views::Assessments::Glossary.thresholds_from(matrix_data),
      emphasised: matrix_data[:emphasised_capabilities], second_person: second_person, part: part, src: src
    )
  end

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
  # @param emphasised [Array<Hash>] `matrix_data[:emphasised_capabilities]` —
  #   the capabilities whose binding changes how a rating lands
  # @param part [Symbol] :modal for the page, :content for a stream into
  #   `CONTENT_ID`, :frame for that frame on its own
  # @param src [String, nil] where the content frame reloads from
  def initialize(components:, state:, subject:, merged_levels:, person_level:, emphasised:, thresholds: {},
                 second_person: true, part: :modal, src: nil)
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
    @part = part
    @src = src
  end

  def view_template
    return content if @part == :content
    return content_frame if @part == :frame

    render Components::Kit::Modal.new(
      id: ID, title: "How is this calculated?", size: :lg, standalone: false,
      panel_data: { controller: "dialog-refresh", dialog_refresh_content_value: CONTENT_ID }
    ) do |modal|
      modal.body { content_frame }
    end
  end

  private

  # No `src`: it loads only when `assessment_sync_controller` points it at
  # `reload_src` after someone else's rating, never on page load.
  def content_frame
    turbo_frame(id: CONTENT_ID, data: { reload_src: @src, assessment_sync_target: "dialogFrame" }) { content }
  end

  def content
    div(class: "space-y-5") do
      arithmetic
      counts_differently
      rules
      not_counted
    end
  end

  # Plain chips, no tips: the rules list below defines both terms once, and a
  # tip per chip resent on every rating stream would carry the same sentence
  # once per capability.
  def counts_differently
    return if @emphasised.empty?

    div do
      h3(class: "text-sm font-semibold text-default mb-2") { "Counts differently for this role" }
      ul(class: "space-y-1 text-sm text-muted") do
        @emphasised.each do |cap|
          li(class: "flex flex-wrap items-center gap-x-2 gap-y-1") do
            span { cap[:name] }
            render Components::Kit::Badge.new(weight_label(cap[:weight])) if PersonDevelopment::Scoring.weighted?(cap[:weight])
            render Components::Kit::Badge.new(glossary.label(:required)) if cap[:required]
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
      h3(class: "text-sm font-semibold text-default mb-2") { "#{@subject} today" }
      render Components::Kit::Card.new(variant: :inset, density: :compact) do |card|
        card.body { arithmetic_rows(parts) }
      end
    end
  end

  def arithmetic_rows(parts)
    div(class: "space-y-1") do
      row("Shown at #{current_code}", parts[:current])
      row("Shown above #{current_code}", parts[:next], sign: "+") if next_level?
      row("Missing below #{current_code}", parts[:missing], sign: "−") if short_below?
      div(class: "flex items-center justify-between gap-3 pt-2 mt-1 " \
                 "border-t border-default") do
        span(class: "text-sm font-semibold text-default") { "Score" }
        span(class: "text-sm font-bold tabular-nums #{tone_text(@state)}", data: { explainer_score: true }) do
          "#{parts[:score]}%"
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
      span(class: "text-sm text-muted") { label }
      span(class: "text-sm tabular-nums text-default") { "#{sign}#{value}%" }
    end
  end

  def short_below?
    @components[:prior].to_f < 1.0
  end

  def rules
    div do
      h3(class: "text-sm font-semibold text-default mb-2") { "How it adds up" }
      ul(class: "space-y-1.5 text-sm text-muted list-disc pl-5") do
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
      h3(class: "text-sm font-semibold text-default mb-2") { "What doesn't count" }
      ul(class: "space-y-1.5 text-sm text-muted list-disc pl-5") do
        li { "Feedback and comments. They are how a rating is discussed and evidenced, never an input to it." }
        li { glossary.definition(:not_rated) }
        li { glossary.definition(:no_expectation) }
      end
    end
  end
end
