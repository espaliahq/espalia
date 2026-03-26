# frozen_string_literal: true

# Per-category contribution pool score label for Turbo Stream targeting.
# Rendered inline in category header rows alongside the CategoryStatus badge.
#
class Views::Assessments::CategoryContributionLabel < Views::Base
  # @param category_id [String]
  # @param category_result [Hash, nil] { pass: Boolean, pool: Float }
  def initialize(category_id:, category_result:)
    @category_id = category_id
    @category_result = category_result
  end

  def view_template
    span(id: "category-contribution-#{@category_id}") do
      if @category_result && @category_result[:pool]
        score = @category_result[:pool].round(2)
        label = score >= 0 ? "+#{score}" : score.to_s

        color =
          if score > 0
            "text-green-600 dark:text-green-400"
          elsif score < 0
            "text-red-600 dark:text-red-400"
          else
            "text-gray-400 dark:text-gray-500"
          end

        span(class: "text-xs font-mono #{color}") { label }
      end
    end
  end
end
