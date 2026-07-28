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
# time") plus class names for three intensities:
# - `chip_bg`  — solid fill for the level chip
# - `pill_bg`  — softer fill for the inline pill (sits next to body text)
# - `dot`      — small marker for the divergent-secondary line
# - `border`   — outline hue for unbacked calibration dots (same intensity
#                as `dot`, so an outlined dot reads as the same rating)
#
module Views::Assessments::FrequencyPalette
  CONFIG = {
    "none" => {
      label:    "None",
      phrase:   "Never",
      chip_bg:  "bg-red-500 dark:bg-red-400",
      chip_txt: "text-red-950",
      pill_bg:  "bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300",
      dot:      "bg-red-500 dark:bg-red-400",
      border:   "border-red-500 dark:border-red-400"
    },
    "some" => {
      label:    "Some",
      phrase:   "Some of the time",
      chip_bg:  "bg-yellow-500 dark:bg-yellow-400",
      chip_txt: "text-yellow-950",
      pill_bg:  "bg-yellow-100 dark:bg-yellow-900/30 text-yellow-800 dark:text-yellow-300",
      dot:      "bg-yellow-500 dark:bg-yellow-400",
      border:   "border-yellow-500 dark:border-yellow-400"
    },
    "occasional" => {
      label:    "Most",
      phrase:   "Most of the time",
      chip_bg:  "bg-green-500 dark:bg-green-400",
      chip_txt: "text-green-950",
      pill_bg:  "bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-300",
      dot:      "bg-green-500 dark:bg-green-400",
      border:   "border-green-500 dark:border-green-400"
    },
    "consistent" => {
      label:    "Consistently",
      phrase:   "Consistently",
      chip_bg:  "bg-blue-500 dark:bg-blue-400",
      chip_txt: "text-blue-950",
      pill_bg:  "bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-300",
      dot:      "bg-blue-500 dark:bg-blue-400",
      border:   "border-blue-500 dark:border-blue-400"
    }
  }.freeze

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
