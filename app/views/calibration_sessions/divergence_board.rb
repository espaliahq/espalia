# frozen_string_literal: true

# The capability divergence board — one row per capability, each
# participating rater's mean positioned as an initialed dot on a shared
# 0–3 axis, sorted by tendency-corrected disagreement (residual spread).
# A ⚠ flag marks likely unclear expectations: capabilities that stay
# divergent after each rater's overall tendency offset is subtracted
# (docs/architecture/calibration-sessions.md, "The unit of calibration").
class Views::CalibrationSessions::DivergenceBoard < Views::Base
  AXIS_MAX = 3.0

  # Distinct dot fills per rater column (cycled). Deliberately NOT the
  # frequency palette — these identify raters, not ratings.
  RATER_DOT_CLASSES = %w[
    bg-teal-600 dark:bg-teal-400
    bg-purple-600 dark:bg-purple-400
    bg-pink-600 dark:bg-pink-400
    bg-indigo-600 dark:bg-indigo-400
    bg-orange-600 dark:bg-orange-400
    bg-cyan-600 dark:bg-cyan-400
  ].each_slice(2).map { |light, dark| "#{light} #{dark}" }.freeze

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

  def legend
    div(class: "mt-3 flex flex-wrap gap-x-4 gap-y-1") do
      @raters.each_with_index do |rater, index|
        div(class: "flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-300") do
          span(class: "inline-block h-3 w-3 rounded-full #{dot_class(index)}", aria: { hidden: "true" })
          plain rater_name(rater[:participant_id])
        end
      end
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
            plain "spread #{sprintf('%.1f', capability[:spread])}"
          end
          if capability[:flagged]
            render Components::Kit::Badge.new("⚠ raters disagree", variant: :warning)
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
                 "justify-center rounded-full text-[10px] font-semibold text-white #{dot_class(index)}",
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

  def rater_index(participant_id)
    @rater_index ||= @raters.each_with_index.to_h { |rater, index| [ rater[:participant_id], index ] }
    @rater_index.fetch(participant_id, 0)
  end

  def dot_class(index)
    RATER_DOT_CLASSES[index % RATER_DOT_CLASSES.size]
  end

  def rater_name(participant_id)
    @people[participant_id]&.name || "Unknown"
  end

  def initials(participant_id)
    rater_name(participant_id).split.map(&:first).first(2).join.upcase
  end
end
