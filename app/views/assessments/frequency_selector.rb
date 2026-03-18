# frozen_string_literal: true

# Three-button segmented control for self-rating frequency.
# Each button submits a form via Turbo Stream.
#
class Views::Assessments::FrequencySelector < Views::Base
  FREQUENCIES = [
    { value: "some", label: "Some", bg: "bg-amber-100 dark:bg-amber-900/30",
      text: "text-amber-800 dark:text-amber-300", ring: "ring-amber-300 dark:ring-amber-700" },
    { value: "occasional", label: "Occasional", bg: "bg-blue-100 dark:bg-blue-900/30",
      text: "text-blue-800 dark:text-blue-300", ring: "ring-blue-300 dark:ring-blue-700" },
    { value: "consistent", label: "Consistent", bg: "bg-green-100 dark:bg-green-900/30",
      text: "text-green-800 dark:text-green-300", ring: "ring-green-300 dark:ring-green-700" }
  ].freeze

  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param current_frequency [String, nil]
  # @param framework_id [String]
  def initialize(capability_stable_id:, level_ordinal:, current_frequency:, framework_id:)
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
    @current_frequency = current_frequency
    @framework_id = framework_id
  end

  def view_template
    div(
      class: "flex gap-1",
      data: { controller: "frequency-selector" }
    ) do
      FREQUENCIES.each { |freq| frequency_button(freq) }
    end
  end

  private

  def frequency_button(freq)
    selected = @current_frequency == freq[:value]

    form(
      action: assessment_ratings_path(@framework_id),
      method: "post",
      data: { turbo_stream: "true" },
      class: "contents"
    ) do
      input(type: "hidden", name: "rating[capability_stable_id]", value: @capability_stable_id)
      input(type: "hidden", name: "rating[level_ordinal]", value: @level_ordinal)
      input(type: "hidden", name: "rating[frequency]", value: freq[:value])

      button(
        type: "submit",
        class: button_classes(freq, selected),
        data: {
          frequency_selector_target: "button",
          action: "frequency-selector#select"
        }
      ) { freq[:label] }
    end
  end

  def button_classes(freq, selected)
    base = "px-2 py-1 text-xs font-medium rounded-md transition-all cursor-pointer "
    if selected
      "#{base}#{freq[:bg]} #{freq[:text]} ring-1 #{freq[:ring]}"
    else
      "#{base}text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 " \
        "hover:bg-gray-100 dark:hover:bg-gray-700"
    end
  end
end
