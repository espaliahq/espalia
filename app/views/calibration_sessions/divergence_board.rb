# frozen_string_literal: true

# The capability divergence board — one row per capability, each
# participating rater's mean positioned as an initialed dot on a shared
# 0–3 axis, sorted by tendency-corrected disagreement (residual spread).
# A ⚠ flag marks likely unclear expectations: capabilities that stay
# divergent after each rater's overall tendency offset is subtracted
# (docs/architecture/calibration-sessions.md, "The unit of calibration").
class Views::CalibrationSessions::DivergenceBoard < Views::Base
  include Views::CalibrationSessions::Glossary

  AXIS_MAX = 3.0

  include Views::CalibrationSessions::RaterColours

  # @param session [CalibrationSession] for drill-in links
  # @param capabilities [Array<Hash>] OverviewStats capability rows (sorted)
  # @param raters [Array<Hash>] OverviewStats rater rows (for the legend/ordering)
  # @param people [Hash{String => Person}]
  # @param insufficient_count [Integer]
  def initialize(session:, capabilities:, raters:, people:, insufficient_count: 0)
    @session = session
    @capabilities = capabilities
    @raters = raters
    @people = people
    @insufficient_count = insufficient_count
  end

  def view_template
    render Components::Kit::Card.new do |card|
      card.body do
        h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          "Capability divergence"
        end
        p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") do
          plain "Each dot is one rater's mean for that capability. " \
                "Sorted by disagreement remaining after each rater's overall tendency is subtracted — " \
                "⚠ marks likely unclear expectations."
        end

        if @capabilities.empty?
          empty_state
          # Most relevant precisely here: a silent rater is often WHY
          # nothing is comparable yet.
          unrated_footnote
        else
          legend
          div(class: "mt-4 space-y-5") do
            @capabilities.each { |capability| capability_row(capability) }
          end
        end

        if @insufficient_count.positive?
          p(class: "mt-4 text-xs text-gray-600 dark:text-gray-300") do
            plain "#{@insufficient_count} #{'capability'.pluralize(@insufficient_count)} rated by only one rater — not comparable yet."
          end
        end
      end
    end
  end

  private

  # Only raters with a dot somewhere on the board. A colour swatch for a
  # rater with no ratings promises a dot that exists on no axis — the
  # unrated are named in a plain footnote instead, which is also the honest
  # shape ("not here yet"), not a legend entry pretending to be data.
  def legend
    div(class: "mt-3 flex flex-wrap gap-x-4 gap-y-1") do
      @raters.each_with_index do |rater, index|
        next if rater[:cell_count].zero?

        div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
          span(class: "inline-block h-3 w-3 rounded-full #{rater_dot_class(index)}", aria: { hidden: "true" })
          plain rater_name(rater[:participant_id])
        end
      end
    end
    unrated_footnote
  end

  def unrated_footnote
    names = @raters.select { |rater| rater[:cell_count].zero? }
      .map { |rater| rater_name(rater[:participant_id]) }
    return if names.empty?

    p(class: "mt-1.5 text-xs italic text-gray-600 dark:text-gray-300") do
      "#{names.to_sentence} #{names.size == 1 ? 'hasn\'t' : 'haven\'t'} rated yet — not on the board."
    end
  end

  def capability_row(capability)
    div do
      div(class: "flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1") do
        div(class: "min-w-0") do
          if capability[:category_name]
            span(class: "text-[10px] font-medium uppercase tracking-wide text-gray-600 dark:text-gray-300 mr-2") do
              capability[:category_name]
            end
          end
          # Persistently underlined + chevroned: this row is the way into the
          # drill-in, and a hover-only affordance hides that on a projector.
          a(
            href: calibration_session_capability_path(@session, capability[:stable_id]),
            class: "group/cap inline-flex items-baseline gap-1 text-sm font-medium " \
                   "text-gray-900 dark:text-white underline decoration-gray-400 " \
                   "dark:decoration-gray-500 underline-offset-4 hover:decoration-gray-900 " \
                   "dark:hover:decoration-white"
          ) do
            plain capability[:name]
            span(class: "text-gray-600 dark:text-gray-300 transition-transform " \
                        "group-hover/cap:translate-x-0.5", aria: { hidden: "true" }) { "›" }
          end
        end
        div(class: "flex items-center gap-2 text-xs") do
          span(class: "text-gray-600 dark:text-gray-300") do
            defined_term(:spread, align: :right, suffix: capability[:stable_id],
                         label: sprintf("spread %.1f", capability[:spread]))
          end
          carried_note(capability)
          if capability[:flagged]
            # The badge itself is the term, so it carries its own definition
            # rather than sitting next to a second affordance.
            defined_term(:raters_disagree, align: :right, suffix: capability[:stable_id],
                         trigger_class: BADGE_TRIGGER)
          end
        end
      end
      axis(capability)
    end
  end

  # A 0–3 track with one positioned, initialed dot per rater. The text
  # equivalent rides the track's aria-label (never colour/position alone).
  def axis(capability)
    summary = capability[:rater_means].map do |participant_id, stats_hash|
      "#{rater_name(participant_id)} #{sprintf('%.1f', stats_hash[:mean])} (n #{stats_hash[:n]})"
    end.join(", ")

    div(class: "relative mt-2 h-7 rounded-full bg-gray-100 dark:bg-gray-800",
        role: "img", aria: { label: "#{capability[:name]} rater means: #{summary}" }) do
      capability[:rater_means].each do |participant_id, stats_hash|
        index = rater_index(participant_id)
        left = (stats_hash[:mean] / AXIS_MAX * 100).clamp(0, 100).round(1)
        div(
          class: "absolute top-1/2 -translate-y-1/2 -translate-x-1/2 flex h-6 w-6 items-center " \
                 "justify-center rounded-full text-[10px] font-semibold text-white #{rater_dot_class(index)}",
          style: "left: #{left}%",
          title: "#{rater_name(participant_id)} — mean #{sprintf('%.2f', stats_hash[:mean])} (n #{stats_hash[:n]})"
        ) { initials(participant_id) }
      end
    end
  end

  def empty_state
    p(class: "mt-4 text-sm text-gray-600 dark:text-gray-300") do
      "Nothing to compare yet — capabilities appear once two raters have rated them."
    end
  end

  # A gap between numbers nobody re-examined this cycle isn't a live
  # disagreement. The row keeps its rank — the divergence is real in the
  # data — but says how much of it is inherited, so the room can decide
  # whether to spend the meeting on it.
  def carried_note(capability)
    carried = capability[:carried_count].to_i
    return if carried.zero?

    total = capability[:cell_count].to_i
    all = total.positive? && carried == total
    span(
      class: "text-amber-700 dark:text-amber-300",
      title: "#{carried} of #{total} ratings behind this comparison were carried forward " \
             "from the previous cycle and not confirmed this one"
    ) { all ? "· all carried" : "· #{carried} of #{total} carried" }
  end

  def rater_index(participant_id)
    @rater_index ||= @raters.each_with_index.to_h { |rater, index| [ rater[:participant_id], index ] }
    @rater_index.fetch(participant_id, 0)
  end

  def rater_name(participant_id)
    @people[participant_id]&.name || "Unknown"
  end

  def initials(participant_id)
    rater_name(participant_id).split.map(&:first).first(2).join.upcase
  end
end
