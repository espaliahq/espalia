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
# because the keyboard-focus ring + selected-state were moved off
# blue onto the brand teal (`ring-primary`); see LevelChip /
# FrequencyPill.
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
# for `none` and `consistent`, but nothing depends on it.
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
      chip_bg:  "bg-red-500 dark:bg-red-400",
      chip_carried: "bg-red-300 dark:bg-red-300",
      chip_carried_border: "border-dashed border-red-600 dark:border-red-500",
      chip_txt: "text-red-950",
      pill_bg:  "bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300",
      pill_carried: "border border-dashed border-red-400 dark:border-red-500 text-red-800 dark:text-red-300 bg-transparent",
      dot:      "bg-red-500 dark:bg-red-400",
      border:   "border-red-500 dark:border-red-400"
    },
    "some" => {
      label:    "Some",
      phrase:   "Some of the time",
      chip_bg:  "bg-yellow-500 dark:bg-yellow-400",
      chip_carried: "bg-yellow-300 dark:bg-yellow-300",
      chip_carried_border: "border-dashed border-yellow-600 dark:border-yellow-500",
      chip_txt: "text-yellow-950",
      pill_bg:  "bg-yellow-100 dark:bg-yellow-900/30 text-yellow-800 dark:text-yellow-300",
      pill_carried: "border border-dashed border-yellow-500 dark:border-yellow-500 text-yellow-800 dark:text-yellow-300 bg-transparent",
      dot:      "bg-yellow-500 dark:bg-yellow-400",
      border:   "border-yellow-500 dark:border-yellow-400"
    },
    "occasional" => {
      label:    "Most",
      phrase:   "Most of the time",
      chip_bg:  "bg-green-500 dark:bg-green-400",
      chip_carried: "bg-green-300 dark:bg-green-300",
      chip_carried_border: "border-dashed border-green-600 dark:border-green-500",
      chip_txt: "text-green-950",
      pill_bg:  "bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-300",
      pill_carried: "border border-dashed border-green-500 dark:border-green-500 text-green-800 dark:text-green-300 bg-transparent",
      dot:      "bg-green-500 dark:bg-green-400",
      border:   "border-green-500 dark:border-green-400"
    },
    "consistent" => {
      label:    "Consistently",
      phrase:   "Consistently",
      chip_bg:  "bg-blue-500 dark:bg-blue-400",
      chip_carried: "bg-blue-300 dark:bg-blue-300",
      chip_carried_border: "border-dashed border-blue-600 dark:border-blue-500",
      chip_txt: "text-blue-950",
      pill_bg:  "bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-300",
      pill_carried: "border border-dashed border-blue-400 dark:border-blue-500 text-blue-800 dark:text-blue-300 bg-transparent",
      dot:      "bg-blue-500 dark:bg-blue-400",
      border:   "border-blue-500 dark:border-blue-400"
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
end
