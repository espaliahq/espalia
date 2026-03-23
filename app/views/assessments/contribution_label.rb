# frozen_string_literal: true

# Per-capability contribution score label for Turbo Stream targeting.
# Rendered inline in matrix row capability names.
#
class Views::Assessments::ContributionLabel < Views::Base
  # @param capability_stable_id [String]
  # @param contribution [Float, nil]
  def initialize(capability_stable_id:, contribution:)
    @capability_stable_id = capability_stable_id
    @contribution = contribution
  end

  def view_template
    span(id: "contribution-#{@capability_stable_id}") do
      if @contribution
        score = @contribution.round(2)
        label = score >= 0 ? "+#{score}" : score.to_s

        color =
          if score > 0
            "text-green-600 dark:text-green-400"
          elsif score < 0
            "text-red-600 dark:text-red-400"
          else
            "text-gray-400 dark:text-gray-500"
          end

        span(class: "text-[10px] font-mono #{color}") { label }
      end
    end
  end
end
