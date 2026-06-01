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
  include Views::Assessments::Concerns::RatedCount

  # @param category_id [String]
  # @param category_result [Hash, nil] primary perspective's { pass: Boolean, pool: Float }
  # @param secondary_results [Array<Array(String, Hash)>] [["Mgr", { pass:, pool: }], ...]
  # @param category_data [Hash, nil] entry from `matrix_data[:categories]` — used to derive rated count
  # @param context [Symbol] :self, :manager, or :alignment — picks which frequency the rated count reads
  def initialize(category_id:, category_result:, secondary_results: [], category_data: nil, context: :self)
    @category_id = category_id
    @category_result = category_result
    @secondary_results = secondary_results
    @category_data = category_data
    @context = context
  end

  def view_template
    span(id: "category-indicators-#{@category_id}", class: "flex flex-col items-end gap-0.5 shrink-0") do
      span(class: "flex items-center gap-2") do
        rated_count_badge
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

  # "3/24 rated" — quiet text count next to the pass/fail pill so
  # in-progress assessments show what's still untouched. Skipped when
  # we don't have category_data to derive the totals from (e.g. legacy
  # callsites that haven't been updated).
  def rated_count_badge
    return unless @category_data

    counts = category_rated_count(@category_data, @context)
    return if counts[:total].zero?

    span(class: "text-[11px] text-gray-600 dark:text-gray-300 tabular-nums whitespace-nowrap") do
      "#{counts[:rated]}/#{counts[:total]} rated"
    end
  end

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
      pass_color = alt_result[:pass] ? "text-green-700 dark:text-green-400" : "text-amber-700 dark:text-amber-400"

      span(class: "flex items-center gap-1") do
        span(class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0") { }
        span(class: "text-[10px] text-gray-600 dark:text-gray-300") { "#{label}:" }
        if pool
          pool_color = pool > 0 ? "text-green-700 dark:text-green-400" :
                       pool < 0 ? "text-red-700 dark:text-red-400" :
                       "text-gray-600 dark:text-gray-300"
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
