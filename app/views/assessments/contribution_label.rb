# frozen_string_literal: true

# Per-capability contribution score label for Turbo Stream targeting.
# Rendered inline in matrix row capability names.
#
# Shows inline secondary perspective values when they diverge from the
# primary (contribution signs differ).
#
class Views::Assessments::ContributionLabel < Views::Base
  # @param capability_stable_id [String]
  # @param contribution [Float, nil]
  # @param secondary_contributions [Array<Array(String, Float)>] [["Mgr", -0.5], ...]
  def initialize(capability_stable_id:, contribution:, secondary_contributions: [])
    @capability_stable_id = capability_stable_id
    @contribution = contribution
    @secondary_contributions = secondary_contributions
  end

  def view_template
    span(id: "contribution-#{@capability_stable_id}", class: "inline-flex flex-col") do
      primary_label
      divergent_annotations
    end
  end

  private

  def primary_label
    return unless @contribution

    score = @contribution.round(2)
    label = score >= 0 ? "+#{score}" : score.to_s
    span(class: "text-[10px] font-mono #{score_color(score)}") { label }
  end

  def divergent_annotations
    return unless @contribution

    @secondary_contributions.each do |label, alt_contribution|
      next unless alt_contribution
      next unless pool_signs_differ?(@contribution, alt_contribution)

      alt_score = alt_contribution.round(2)
      alt_label = alt_score >= 0 ? "+#{alt_score}" : alt_score.to_s

      span(class: "flex items-center gap-0.5") do
        span(class: "w-1 h-1 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0") { }
        span(class: "text-[9px] text-gray-600 dark:text-gray-300") { "#{label}:" }
        span(class: "text-[9px] font-mono #{score_color(alt_score)}") { alt_label }
      end
    end
  end

  def score_color(score)
    if score > 0
      "text-green-700 dark:text-green-400"
    elsif score < 0
      "text-red-700 dark:text-red-400"
    else
      "text-gray-600 dark:text-gray-300"
    end
  end

  def pool_signs_differ?(a, b)
    (a > 0 && b < 0) || (a < 0 && b > 0)
  end
end
