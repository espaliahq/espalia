# frozen_string_literal: true

# Wrapper for category contribution label, status badge, and divergence annotations.
#
# Renders as a single Turbo Stream target so that all indicators update
# atomically when a rating changes the scoring perspective.
#
# Shows inline secondary perspective values when they diverge from the
# primary (pass/fail differs or pool signs differ).
#
class Views::Assessments::CategoryIndicators < Views::Base
  # @param category_id [String]
  # @param category_result [Hash, nil] primary perspective's { pass: Boolean, pool: Float }
  # @param secondary_results [Array<Array(String, Hash)>] [["Mgr", { pass:, pool: }], ...]
  def initialize(category_id:, category_result:, secondary_results: [])
    @category_id = category_id
    @category_result = category_result
    @secondary_results = secondary_results
  end

  def view_template
    span(id: "category-indicators-#{@category_id}", class: "flex flex-col items-end gap-0.5 shrink-0") do
      span(class: "flex items-center gap-2") do
        render Views::Assessments::CategoryContributionLabel.new(
          category_id: @category_id,
          category_result: @category_result
        )
        render Views::Assessments::CategoryStatus.new(
          category_id: @category_id,
          category_result: @category_result
        )
      end
      divergent_annotations
    end
  end

  private

  # Renders compact annotations for each divergent secondary perspective.
  #
  def divergent_annotations
    return unless @category_result

    @secondary_results.each do |label, alt_result|
      next unless alt_result
      next unless divergent?(alt_result)

      pool = alt_result[:pool]&.round(2)
      pool_label = pool && pool >= 0 ? "+#{pool}" : pool.to_s
      pass_label = alt_result[:pass] ? "Pass" : "Below"
      pass_color = alt_result[:pass] ? "text-green-600 dark:text-green-400" : "text-amber-600 dark:text-amber-400"

      span(class: "flex items-center gap-1") do
        span(class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0") { }
        span(class: "text-[10px] text-gray-400 dark:text-gray-500") { "#{label}:" }
        if pool
          pool_color = pool > 0 ? "text-green-600 dark:text-green-400" :
                       pool < 0 ? "text-red-600 dark:text-red-400" :
                       "text-gray-400 dark:text-gray-500"
          span(class: "text-[10px] font-mono #{pool_color}") { pool_label }
        end
        span(class: "text-[10px] font-medium #{pass_color}") { pass_label }
      end
    end
  end

  # Whether a secondary result meaningfully diverges from the primary.
  #
  # @param alt_result [Hash] { pass:, pool: }
  # @return [Boolean]
  def divergent?(alt_result)
    alt_result[:pass] != @category_result[:pass] ||
      pool_signs_differ?(@category_result[:pool], alt_result[:pool])
  end

  def pool_signs_differ?(a, b)
    return false unless a && b

    (a > 0 && b < 0) || (a < 0 && b > 0)
  end
end
