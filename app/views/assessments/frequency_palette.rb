# frozen_string_literal: true

# Single source of truth for the four-state frequency palette.
#
# The same colours back the inline FrequencyPill, the level-strip
# LevelChip, the divergent-secondary line, and any future surface
# that reads a frequency. The palette intentionally walks a
# red → orange → amber → green ramp so the four states read as
# a clear gradient ("worse → better") regardless of text labels.
#
# Each entry carries the rating's display phrase ("Most of the
# time") plus class names for three intensities:
# - `chip_bg`  — solid fill for the level chip
# - `pill_bg`  — softer fill for the inline pill (sits next to body text)
# - `dot`      — small marker for the divergent-secondary line
#
module Views::Assessments::FrequencyPalette
  CONFIG = {
    "none" => {
      label:    "None",
      phrase:   "Never",
      chip_bg:  "bg-red-500 dark:bg-red-400",
      chip_txt: "text-white dark:text-red-950",
      pill_bg:  "bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300",
      dot:      "bg-red-500 dark:bg-red-400"
    },
    "some" => {
      label:    "Some",
      phrase:   "Some of the time",
      chip_bg:  "bg-orange-500 dark:bg-orange-400",
      chip_txt: "text-white dark:text-orange-950",
      pill_bg:  "bg-orange-100 dark:bg-orange-900/30 text-orange-800 dark:text-orange-300",
      dot:      "bg-orange-500 dark:bg-orange-400"
    },
    "occasional" => {
      label:    "Most",
      phrase:   "Most of the time",
      chip_bg:  "bg-amber-500 dark:bg-amber-400",
      chip_txt: "text-white dark:text-amber-950",
      pill_bg:  "bg-amber-100 dark:bg-amber-900/30 text-amber-800 dark:text-amber-300",
      dot:      "bg-amber-500 dark:bg-amber-400"
    },
    "consistent" => {
      label:    "Consistently",
      phrase:   "Consistently",
      chip_bg:  "bg-green-500 dark:bg-green-400",
      chip_txt: "text-white dark:text-green-950",
      pill_bg:  "bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-300",
      dot:      "bg-green-500 dark:bg-green-400"
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
