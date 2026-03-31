# frozen_string_literal: true

# Read-only frequency indicator bar showing a secondary rating perspective.
#
# Renders a compact colored strip with a label, frequency value, and
# an optional divergence dot when the rating differs from the primary.
#
# @example
#   render Views::Assessments::FrequencyBar.new(
#     label: "Mgr", frequency: "occasional", primary_frequency: "consistent"
#   )
#   # => Mgr  ████████  Occ.  ⚠
#
class Views::Assessments::FrequencyBar < Views::Base
  FREQUENCY_CONFIG = {
    "none"       => { label: "None", width: "w-1/12",  bg: "bg-gray-300 dark:bg-gray-600" },
    "some"       => { label: "Some", width: "w-3/12",  bg: "bg-amber-300 dark:bg-amber-700" },
    "occasional" => { label: "Occ.",  width: "w-6/12",  bg: "bg-blue-300 dark:bg-blue-700" },
    "consistent" => { label: "Cons.", width: "w-full",  bg: "bg-green-300 dark:bg-green-700" }
  }.freeze

  # @param label [String] "Self", "Mgr", or "Agreed"
  # @param frequency [String, nil] the frequency value
  # @param primary_frequency [String, nil] the primary rating for divergence comparison
  def initialize(label:, frequency:, primary_frequency: nil)
    @label = label
    @frequency = frequency
    @primary_frequency = primary_frequency
  end

  def view_template
    return unless @frequency

    config = FREQUENCY_CONFIG[@frequency]
    return unless config

    diverges = @primary_frequency.present? && @frequency != @primary_frequency

    div(class: "flex items-center gap-1.5 mt-1") do
      # Label
      span(class: "text-[10px] text-gray-400 dark:text-gray-500 w-8 shrink-0") { "#{@label}:" }

      # Colored bar
      div(class: "flex-1 h-1.5 rounded-full bg-gray-100 dark:bg-gray-800 overflow-hidden") do
        div(class: "h-full rounded-full #{config[:bg]} #{config[:width]}")
      end

      # Frequency label
      span(class: "text-[10px] text-gray-500 dark:text-gray-400 w-7 shrink-0 text-right") do
        config[:label]
      end

      # Divergence indicator
      if diverges
        span(
          class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0",
          title: "Differs from your rating"
        ) { }
      else
        span(class: "w-1.5 shrink-0") { }
      end
    end
  end
end
