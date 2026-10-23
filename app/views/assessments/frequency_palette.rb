# frozen_string_literal: true

# Single source of truth for the four-state frequency palette.
#
# The same colours back the inline FrequencyPill, the level-strip
# LevelChip, the divergent-secondary line, and any future surface
# that reads a frequency. The palette walks a
# red → yellow → green → blue scale — four maximally-distinct hues
# so adjacent states never blur. This replaces the old
# red → orange → amber → green ramp, whose middle two (orange "Some"
# vs amber "Most") were near-indistinguishable on small chips and
# in a diagonal split.
#
# Ordering is carried by chip position (E1…E8 left→right) and the
# text label, NOT by a single-axis colour gradient — so blue marking
# the top "Consistently" tier reads as a distinct band rather than
# "even greener than green". Blue is only safe as a rating colour
# because the keyboard-focus ring + selected-state are neutral
# (`ring-focus`), never blue; see LevelChip / FrequencyPill.
#
# Each entry carries the rating's display phrase ("Most of the
# time") plus class names for three intensities. The bottom of the
# scale is deliberately "Not yet", not "None"/"Never": the domain value
# stays `none` (events, read models, MCP enum), but the surface word
# frames the lowest rating as a starting point rather than a verdict —
# the "Feedback / Evidence" relabel convention (assessments.md).
# `phrase` is the sentence form (pill, secondary line, aria text, the
# live-status announcement); `label` is the compact form (feed secondary
# line, calibration distribution summary). They may coincide, as they do
# for `none` and `consistent`, but nothing depends on it. `spoken` is an
# optional override for sentences that COMPOSE the phrase after a verb
# ("rated …" in the chip's accessible name, the live-status
# announcement): "rated not yet" means the opposite of what it says, so
# `none` composes as "rated not yet demonstrated".
#
# - `chip_bg`  — solid fill for the level chip
# - `pill_bg`  — softer fill for the inline pill (sits next to body text)
# - `dot`      — small marker for the divergent-secondary line
# - `border`   — outline hue for unbacked calibration dots (same intensity
#                as `dot`, so an outlined dot reads as the same rating)
#
module Views::Assessments::FrequencyPalette
  CONFIG = {
    "none" => {
      label:    "Not yet",
      phrase:   "Not yet",
      spoken:   "not yet demonstrated",
      chip_bg:  "bg-rating-none",
      chip_carried: "bg-rating-none-carried",
      chip_carried_border: "border-dashed border-rating-none-carried",
      chip_txt: "text-rating-none-chip",
      pill_bg:  "bg-rating-none-pill text-rating-none-pill",
      pill_carried: "border border-dashed border-rating-none-pill-carried text-rating-none-pill bg-transparent",
      dot:      "bg-rating-none",
      border:   "border-rating-none"
    },
    "some" => {
      label:    "Some",
      phrase:   "Some of the time",
      chip_bg:  "bg-rating-some",
      chip_carried: "bg-rating-some-carried",
      chip_carried_border: "border-dashed border-rating-some-carried",
      chip_txt: "text-rating-some-chip",
      pill_bg:  "bg-rating-some-pill text-rating-some-pill",
      pill_carried: "border border-dashed border-rating-some-pill-carried text-rating-some-pill bg-transparent",
      dot:      "bg-rating-some",
      border:   "border-rating-some"
    },
    "occasional" => {
      label:    "Most",
      phrase:   "Most of the time",
      chip_bg:  "bg-rating-occasional",
      chip_carried: "bg-rating-occasional-carried",
      chip_carried_border: "border-dashed border-rating-occasional-carried",
      chip_txt: "text-rating-occasional-chip",
      pill_bg:  "bg-rating-occasional-pill text-rating-occasional-pill",
      pill_carried: "border border-dashed border-rating-occasional-pill-carried text-rating-occasional-pill bg-transparent",
      dot:      "bg-rating-occasional",
      border:   "border-rating-occasional"
    },
    "consistent" => {
      label:    "Consistently",
      phrase:   "Consistently",
      chip_bg:  "bg-rating-consistent",
      chip_carried: "bg-rating-consistent-carried",
      chip_carried_border: "border-dashed border-rating-consistent-carried",
      chip_txt: "text-rating-consistent-chip",
      pill_bg:  "bg-rating-consistent-pill text-rating-consistent-pill",
      pill_carried: "border border-dashed border-rating-consistent-pill-carried text-rating-consistent-pill bg-transparent",
      dot:      "bg-rating-consistent",
      border:   "border-rating-consistent"
    }
  }.freeze

  # Carried-forward (seeded, not yet confirmed) treatment: the SAME hue at
  # reduced intensity — a lighter fill on chips, a dashed outline on pills —
  # mirroring the assumed-consistent below-level precedent (lighter shade =
  # inherited, solid = explicit). The chip ADDITIONALLY carries a dashed
  # border in its hue (`chip_carried_border`): dashed is the universal
  # "carried" signal across surfaces, and it keeps a carried-consistent
  # chip (blue-300 fill) distinguishable from the assumed-consistent
  # below-level fill, which is the same blue-300 in light mode. Colour
  # stays the rating language; carried state must additionally be conveyed
  # non-visually (title / aria) by every surface that renders it.

  ORDERED_KEYS = %w[none some occasional consistent].freeze

  module_function

  # Returns the config hash for a frequency, or nil for an unknown /
  # nil value.
  def config_for(frequency)
    CONFIG[frequency]
  end

  # Lowercase sentence phrase for embedding inline ("...Most of the time").
  def phrase_for(frequency)
    config_for(frequency)&.dig(:phrase) || "Not rated"
  end

  # Compact label for tight spaces ("Most", "Consistently").
  def label_for(frequency)
    config_for(frequency)&.dig(:label) || "Unrated"
  end

  # Lowercase form for composing after a verb ("rated most of the time",
  # "rated not yet demonstrated"). Falls back to the phrase, so only a
  # rating whose phrase misreads after "rated" needs a `spoken` entry.
  def spoken_for(frequency)
    config_for(frequency)&.dig(:spoken) || phrase_for(frequency).downcase
  end
end
