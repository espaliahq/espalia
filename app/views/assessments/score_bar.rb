# frozen_string_literal: true

# The score's scale made visible: a track whose first segment is the
# assessed level (0–100) and whose further segments are the levels above,
# one per band the cap allows, divided at each 100 mark. The same bar at
# three sizes — the hero (:lg, tick-labelled with the level codes), a
# category header (:md) and a capability card (:sm) — so the number reads
# identically at every altitude. At the top of the ladder it is a single
# 0–100 segment.
#
# Accessible as a progressbar whose label spells the scale out; the tick
# labels are decorative and hidden from assistive tech.
class Views::Assessments::ScoreBar < Views::Base
  include Views::Assessments::Concerns::ScoreScale

  SIZES = {
    lg: { wrap: "mt-2 w-36 sm:w-44 ml-auto", track: "h-1.5", divider: "w-0.5" },
    md: { wrap: "w-28", track: "h-1", divider: "w-px" },
    sm: { wrap: "w-20", track: "h-1", divider: "w-px" }
  }.freeze

  # @param score [Float] the 0.0–N score
  # @param state [Symbol] the performance state (drives the fill colour)
  # @param components [Hash, nil] the components hash (for :bands_above)
  # @param merged_levels [Array<Hash>] the role's levels (:ordinal, :level_code)
  # @param person_level [Integer] the assessed level ordinal
  # @param size [Symbol] :lg | :md | :sm
  # @param id [String, nil] DOM id for the wrapper
  def initialize(score:, state:, components:, merged_levels:, person_level:, size: :sm, id: nil)
    @score = score.to_f
    @state = state
    @components = components
    @merged_levels = merged_levels
    @person_level = person_level
    @size = SIZES.fetch(size)
    @labelled = size == :lg
    @id = id
  end

  def view_template
    bands = bands_for(@components)
    max = 100 * (1 + bands)
    pct = percent(@score)
    fill = ([ pct, max ].min.to_f / max * 100).round(1)
    label = if bands.positive?
      "#{pct}% — 100% is #{current_code} expectations, #{max}% is #{code_above(bands - 1)}"
    else
      "#{pct}% — 100% is #{current_code} expectations, the top of the ladder"
    end

    div(id: @id, class: @size[:wrap], data: { score_bar: "true" }) do
      div(class: "relative #{@size[:track]} rounded-full bg-neutral-muted overflow-hidden",
          role: "progressbar",
          aria: { valuenow: [ pct, max ].min, valuemin: 0, valuemax: max, label: label }) do
        div(class: "h-full rounded-full #{tone_bar(@state)}", style: "width: #{fill}%") { }
        (1..bands).each do |i|
          span(class: "absolute inset-y-0 #{@size[:divider]} bg-overlay",
               style: "left: #{(100.0 * i / (bands + 1)).round(2)}%", aria: { hidden: "true" }) { }
        end
      end
      tick_labels(bands) if @labelled
    end
  end

  private

  def tick_labels(bands)
    div(class: "mt-1 flex justify-between text-[10px] text-muted tabular-nums",
        aria: { hidden: "true" }) do
      span { "0" }
      span { "100% · #{current_code}" }
      (1..bands).each { |i| span { "#{100 * (i + 1)}% · #{code_above(i - 1)}" } }
    end
  end
end
