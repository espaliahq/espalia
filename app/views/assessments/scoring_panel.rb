# frozen_string_literal: true

# Scoring summary sidebar for the assessment view.
#
# Three-tier performance signal:
# 1. Below expectations (< 1.0) — performance concern
# 2. Meeting expectations (≥ 1.0) — at baseline
# 3. Mastering (≥ 1.25 default) — significantly exceeding
#
# Wrapped in a targetable div for Turbo Stream replacement.
#
class Views::Assessments::ScoringPanel < Views::Base
  # @param scoring [Hash] from MatrixDataBuilder scoring output
  # @param categories [Array<Hash>] category data from MatrixDataBuilder
  # @param person_level [Integer]
  def initialize(scoring:, categories:, person_level:)
    @scoring = scoring
    @categories = categories
    @person_level = person_level
  end

  def view_template
    div(id: "scoring-panel", class: "p-5 space-y-6") do
      performance_section
      status_tier_section
      category_results_section
      promotion_section
    end
  end

  private

  def performance_section
    ratio = @scoring[:performance_ratio] || 0.0
    pct = (ratio * 100).round(0)

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "Performance" }

      div(class: "flex items-baseline gap-2 mb-2") do
        span(class: "text-3xl font-bold #{performance_color(ratio)}") { "#{pct}%" }
        span(class: "text-xs text-gray-500 dark:text-gray-400") { "of expected" }
      end

      # Progress bar
      div(class: "w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2") do
        width = [ pct, 150 ].min.to_f / 1.5  # scale so 150% fills the bar
        div(class: "#{performance_bar_color(ratio)} h-2 rounded-full transition-all duration-300",
            style: "width: #{[ width, 100 ].min.round(0)}%") { }
      end
    end
  end

  def status_tier_section
    meeting = @scoring[:meeting_expectations]
    mastering = @scoring[:mastering]

    div(class: "space-y-2") do
      if mastering
        status_badge(
          "Mastering",
          "Significantly exceeding expectations",
          "bg-purple-50 dark:bg-purple-900/20 border-purple-200 dark:border-purple-800",
          "text-purple-800 dark:text-purple-300"
        )
      elsif meeting
        status_badge(
          "Meeting expectations",
          "Performing at or above current level baseline",
          "bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800",
          "text-green-800 dark:text-green-300"
        )
      else
        status_badge(
          "Below expectations",
          "Performance is below current level baseline",
          "bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800",
          "text-red-800 dark:text-red-300"
        )
      end
    end
  end

  def status_badge(title, description, container_classes, text_classes)
    div(class: "p-3 rounded-md border #{container_classes}") do
      span(class: "text-sm font-medium #{text_classes}") { title }
      p(class: "mt-0.5 text-xs #{text_classes} opacity-75") { description }
    end
  end

  def category_results_section
    results = @scoring[:category_results] || {}
    return if results.empty?

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "Categories" }

      div(class: "space-y-2") do
        @categories.each do |cat_data|
          category = cat_data[:category]
          result = results[category.category_id]
          category_result_row(category, result)
        end
      end
    end
  end

  def category_result_row(category, result)
    div(class: "flex items-center justify-between py-1.5 px-2 rounded-md " \
               "bg-white dark:bg-gray-800/50") do
      span(class: "text-sm text-gray-700 dark:text-gray-300 truncate mr-2") { category.name }

      render Views::Assessments::CategoryStatus.new(
        category_id: category.category_id,
        category_result: result
      )
    end
  end

  def promotion_section
    readiness = @scoring[:promotion_readiness]
    return unless readiness

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") do
        "Promotion to L#{@person_level + 1}"
      end

      if readiness[:eligible]
        div(class: "p-3 rounded-md bg-green-50 dark:bg-green-900/20 " \
                   "border border-green-200 dark:border-green-800") do
          span(class: "text-sm font-medium text-green-800 dark:text-green-300") do
            "Eligible for promotion"
          end
        end
      else
        div(class: "p-3 rounded-md bg-gray-50 dark:bg-gray-800 " \
                   "border border-gray-200 dark:border-gray-700") do
          span(class: "text-sm text-gray-600 dark:text-gray-400") { "Not yet eligible" }

          blocked = readiness[:blocked_at_next_level] || []
          if blocked.any?
            p(class: "mt-1 text-xs text-gray-500 dark:text-gray-500") do
              "#{blocked.size} blocked #{'capability'.pluralize(blocked.size)} at L#{@person_level + 1}"
            end
          end

          unless readiness[:meets_score_threshold]
            p(class: "mt-1 text-xs text-gray-500 dark:text-gray-500") do
              "Score threshold not met"
            end
          end
        end
      end
    end
  end

  def performance_color(ratio)
    if ratio >= 1.25
      "text-purple-600 dark:text-purple-400"
    elsif ratio >= 1.0
      "text-green-600 dark:text-green-400"
    elsif ratio >= 0.8
      "text-amber-600 dark:text-amber-400"
    else
      "text-red-600 dark:text-red-400"
    end
  end

  def performance_bar_color(ratio)
    if ratio >= 1.25
      "bg-purple-500"
    elsif ratio >= 1.0
      "bg-green-500"
    elsif ratio >= 0.8
      "bg-amber-500"
    else
      "bg-red-500"
    end
  end
end
