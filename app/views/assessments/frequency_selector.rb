# frozen_string_literal: true

# Four-button segmented control for rating frequency.
# Context-aware: posts to the correct endpoint based on assessment context.
# Each button submits a form via Turbo Stream.
#
class Views::Assessments::FrequencySelector < Views::Base
  FREQUENCIES = [
    { value: "none", short_label: "None", long_label: "None",
      bg: "bg-gray-200 dark:bg-gray-600",
      text: "text-gray-700 dark:text-gray-200", ring: "ring-gray-400 dark:ring-gray-500" },
    { value: "some", short_label: "Some", long_label: "Some times",
      bg: "bg-amber-100 dark:bg-amber-900/30",
      text: "text-amber-800 dark:text-amber-300", ring: "ring-amber-300 dark:ring-amber-700" },
    { value: "occasional", short_label: "Most", long_label: "Most times",
      bg: "bg-blue-100 dark:bg-blue-900/30",
      text: "text-blue-800 dark:text-blue-300", ring: "ring-blue-300 dark:ring-blue-700" },
    { value: "consistent", short_label: "Consistently", long_label: "Consistently",
      bg: "bg-green-100 dark:bg-green-900/30",
      text: "text-green-800 dark:text-green-300", ring: "ring-green-300 dark:ring-green-700" }
  ].freeze

  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param current_frequency [String, nil]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param category_id [String, nil] active category for tab preservation on rating
  def initialize(capability_stable_id:, level_ordinal:, current_frequency:, assessment_id:, context: :self,
                 category_id: nil)
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
    @current_frequency = current_frequency
    @assessment_id = assessment_id
    @context = context
    @category_id = category_id
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
      action: form_action,
      method: "post",
      data: { turbo_stream: "true" },
      class: "contents"
    ) do
      input(type: "hidden", name: "rating[capability_stable_id]", value: @capability_stable_id)
      input(type: "hidden", name: "rating[level_ordinal]", value: @level_ordinal)
      input(type: "hidden", name: "rating[frequency]", value: freq[:value])
      input(type: "hidden", name: "rating[category_id]", value: @category_id) if @category_id

      button(
        type: "submit",
        class: button_classes(freq, selected),
        title: freq[:long_label],
        aria: { label: freq[:long_label] },
        data: {
          frequency_selector_target: "button",
          action: "frequency-selector#select"
        }
      ) { freq[:short_label] }
    end
  end

  # Returns the form action path based on assessment context.
  #
  # @return [String]
  def form_action
    case @context
    when :manager
      assessment_manager_ratings_path(@assessment_id)
    else
      assessment_ratings_path(@assessment_id)
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
