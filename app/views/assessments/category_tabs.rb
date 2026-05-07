# frozen_string_literal: true

# Horizontal tab bar for switching between capability categories in the assessment.
# Rendered inside the Turbo Frame so active state stays in sync on every frame load.
#
# Each tab is an <a> that targets the assessment-matrix Turbo Frame, causing a
# server-side re-render of the matrix with the selected category.
#
# The active tab shows full category scoring (pool score, pass/fail badge,
# divergence annotations) — the same information previously in the category header.
# Inactive tabs show a compact view with status dot, name, and progress.
#
class Views::Assessments::CategoryTabs < Views::Base
  # @param categories [Array<Hash>] all category data from MatrixDataBuilder
  # @param scoring [Hash] primary scoring perspective output
  # @param self_scoring [Hash, nil] self-only perspective scoring
  # @param manager_scoring [Hash, nil] manager-only perspective scoring
  # @param aligned_scoring [Hash, nil] aligned-only perspective scoring
  # @param active_category_id [String] currently selected category ID
  # @param assessment_id [String] UUID for building matrix URLs
  # @param context [Symbol] :self, :manager, or :alignment
  def initialize(categories:, scoring:, active_category_id:, assessment_id:, context: :self,
                 self_scoring: nil, manager_scoring: nil, aligned_scoring: nil)
    @categories = categories
    @scoring = scoring
    @self_scoring = self_scoring
    @manager_scoring = manager_scoring
    @aligned_scoring = aligned_scoring
    @active_category_id = active_category_id
    @assessment_id = assessment_id
    @context = context
  end

  def view_template
    nav(
      id: "category-tabs",
      class: "flex flex-wrap gap-1 border-b border-gray-200 dark:border-gray-700 " \
             "bg-white dark:bg-gray-900 px-3 py-1 sticky top-0 z-30",
      aria_label: "Category tabs"
    ) do
      @categories.each do |cat_data|
        category_tab(cat_data)
      end
    end
  end

  private

  def category_tab(cat_data)
    category = cat_data[:category]
    cat_id = category.category_id
    active = cat_id == @active_category_id
    result = @scoring[:category_results]&.dig(cat_id)
    progress = tab_progress(cat_data)

    a(
      href: matrix_assessment_path(@assessment_id, matrix_link_params(cat_id)),
      data: { turbo_frame: "assessment-matrix" },
      class: tab_classes(active),
      aria_current: (active ? "page" : nil)
    ) do
      div(class: "flex items-center gap-1.5") do
        status_dot(result)
        span(class: active ? "font-semibold" : "") { category.name }
      end
      if active
        active_tab_scoring(cat_id, result, cat_data, progress)
      else
        inactive_tab_info(progress, active)
      end
    end
  end

  # Full scoring detail shown on the active tab.
  def active_tab_scoring(cat_id, result, cat_data, progress)
    div(class: "flex flex-wrap items-center gap-2 mt-0.5") do
      # Pool score
      pool_label(result)
      # Pass/Below badge
      pass_badge(result)
      # Tolerance indicator
      render Components::Kit::CategoryToleranceIndicator.new(
        threshold: cat_data[:deficit_threshold]
      )
      # Progress
      span(class: "text-[10px] text-gray-500 dark:text-gray-400") do
        "#{progress[:rated]}/#{progress[:total]} rated"
      end
    end
    # Divergence annotations
    divergence_annotations(cat_id, result)
  end

  # Compact info for inactive tabs.
  def inactive_tab_info(progress, active)
    span(class: "text-[10px] #{active ? 'text-gray-600 dark:text-gray-300' : 'text-gray-400 dark:text-gray-500'}") do
      "#{progress[:rated]}/#{progress[:total]}"
    end
  end

  def pool_label(result)
    return unless result&.dig(:pool)

    score = result[:pool].round(2)
    label = score >= 0 ? "+#{score}" : score.to_s
    color = if score > 0
              "text-green-600 dark:text-green-400"
    elsif score < 0
              "text-red-600 dark:text-red-400"
    else
              "text-gray-400 dark:text-gray-500"
    end
    span(class: "text-xs font-mono #{color}") { label }
  end

  def pass_badge(result)
    if result.nil?
      span(class: "text-[10px] font-medium text-gray-400 dark:text-gray-500 " \
                  "bg-gray-100 dark:bg-gray-700 rounded-full px-1.5 py-0.5") { "N/A" }
    elsif result[:pass]
      span(class: "text-[10px] font-medium text-green-700 dark:text-green-300 " \
                  "bg-green-100 dark:bg-green-900/30 rounded-full px-1.5 py-0.5") { "Pass" }
    else
      span(class: "text-[10px] font-medium text-amber-700 dark:text-amber-300 " \
                  "bg-amber-100 dark:bg-amber-900/30 rounded-full px-1.5 py-0.5") { "Below" }
    end
  end

  # Shows secondary perspective divergence when pass/fail or pool signs differ.
  def divergence_annotations(cat_id, primary_result)
    return unless primary_result

    secondary_scorings.each do |label, scoring|
      alt_result = scoring[:category_results]&.dig(cat_id)
      next unless alt_result
      next unless divergent?(primary_result, alt_result)

      pool = alt_result[:pool]&.round(2)
      pool_text = pool && pool >= 0 ? "+#{pool}" : pool.to_s
      pass_label = alt_result[:pass] ? "Pass" : "Below"
      pass_color = alt_result[:pass] ? "text-green-600 dark:text-green-400" : "text-amber-600 dark:text-amber-400"

      div(class: "flex items-center gap-1 mt-0.5") do
        span(class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0") { }
        span(class: "text-[10px] text-gray-400 dark:text-gray-500") { "#{label}:" }
        if pool
          pool_color = pool > 0 ? "text-green-600 dark:text-green-400" :
                       pool < 0 ? "text-red-600 dark:text-red-400" :
                       "text-gray-400 dark:text-gray-500"
          span(class: "text-[10px] font-mono #{pool_color}") { pool_text }
        end
        span(class: "text-[10px] font-medium #{pass_color}") { pass_label }
      end
    end
  end

  def divergent?(primary, alt)
    alt[:pass] != primary[:pass] || pool_signs_differ?(primary[:pool], alt[:pool])
  end

  def pool_signs_differ?(a, b)
    return false unless a && b

    (a > 0 && b < 0) || (a < 0 && b > 0)
  end

  def matrix_link_params(cat_id)
    { category: cat_id }
  end

  def tab_classes(active)
    base = "flex flex-col items-center gap-0.5 px-3 py-2 text-xs font-medium " \
           "text-center rounded-t-md transition-colors "
    if active
      "#{base}text-gray-900 dark:text-white bg-gray-50 dark:bg-gray-800 " \
        "border-b-2 border-primary"
    else
      "#{base}text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300 " \
        "hover:bg-gray-50 dark:hover:bg-gray-800/50"
    end
  end

  def status_dot(result)
    color = if result.nil?
              "bg-gray-300 dark:bg-gray-600"
    elsif result[:pass]
              "bg-green-500"
    else
              "bg-red-500"
    end

    span(class: "w-1.5 h-1.5 rounded-full #{color} shrink-0") { }
  end

  # Counts rated and total cells for a category based on context.
  #
  # @param cat_data [Hash] category data from MatrixDataBuilder
  # @return [Hash{Symbol => Integer}] :rated and :total
  def tab_progress(cat_data)
    total = 0
    rated = 0

    cat_data[:capabilities].each do |cap_data|
      cap_data[:cells].each_value do |cell|
        total += 1
        freq = case @context
        when :manager then cell[:manager_frequency]
        when :alignment then cell[:aligned_frequency]
        else cell[:current_frequency]
        end
        rated += 1 if freq.present?
      end
    end

    { rated: rated, total: total }
  end

  # Returns secondary scoring pairs for divergence display.
  #
  # @return [Array<Array(String, Hash)>]
  def secondary_scorings
    @secondary_scorings ||= begin
      all = []
      case @context
      when :self
        all << [ "Mgr", @manager_scoring ] if @manager_scoring
        all << [ "Agreed", @aligned_scoring ] if @aligned_scoring
      when :manager
        all << [ "Self", @self_scoring ] if @self_scoring
        all << [ "Agreed", @aligned_scoring ] if @aligned_scoring
      when :alignment
        all << [ "Self", @self_scoring ] if @self_scoring
        all << [ "Mgr", @manager_scoring ] if @manager_scoring
      end
      all
    end
  end
end
