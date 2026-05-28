# frozen_string_literal: true

# Horizontal chip bar for category navigation in the card-based assessment view.
#
# Each chip is an anchor link that smooth-scrolls to the category section,
# carrying a pass/fail status dot and optional % score. Carries
# `id="category-tabs"` for Turbo Stream replacement by rating controllers.
#
class Views::Assessments::CategoryChipBar < Views::Base
  FREQUENCY_LEGEND = [
    { label: "Consistently", color: "bg-green-300 dark:bg-green-500" },
    { label: "Most",         color: "bg-blue-200 dark:bg-blue-500" },
    { label: "Some",         color: "bg-amber-200 dark:bg-amber-500" },
    { label: "None",         color: "bg-gray-300 dark:bg-gray-500" }
  ].freeze

  # @param categories [Array<Hash>] from MatrixDataBuilder
  # @param scoring [Hash] primary scoring for the context
  # @param active_category_id [String, nil] highlighted chip
  # @param context [Symbol]
  def initialize(categories:, scoring:, active_category_id: nil, context: :self)
    @categories = categories
    @scoring = scoring
    @active_category_id = active_category_id
    @context = context
  end

  def view_template
    nav(id: "category-tabs",
        class: "flex flex-wrap items-center gap-2") do
      all_chip
      @categories.each { |cat_data| category_chip(cat_data) }
      spacer
      legend
    end
  end

  private

  def all_chip
    total = @categories.sum { |c| c[:capabilities].size }
    a(
      href: "#",
      class: "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm font-medium " \
             "#{@active_category_id.nil? ? active_chip_classes : inactive_chip_classes}",
      data: { action: "click->matrix#scrollToTop" }
    ) do
      plain "All"
      span(class: "text-xs font-mono opacity-70") { total.to_s }
    end
  end

  def category_chip(cat_data)
    category = cat_data[:category]
    result = @scoring[:category_results]&.dig(category.category_id)
    active = category.category_id == @active_category_id

    attrs = {
      href: "#category-#{category.category_id}",
      class: "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm font-medium " \
             "#{active ? active_chip_classes : inactive_chip_classes} " \
             "scroll-smooth",
      data: { category_id: category.category_id,
              action: "click->matrix#scrollToCategory" }
    }
    attrs[:aria] = { current: "page" } if active
    a(**attrs) do
      status_dot(result)
      plain category.name
      pct_badge(result, active)
    end
  end

  def status_dot(result)
    return unless result

    pass = result[:pass]
    color = pass ? "bg-green-500" : "bg-red-500"
    span(
      class: "w-2 h-2 rounded-full #{color} shrink-0",
      data: { category_status: pass ? "pass" : "fail" }
    ) { }
  end

  def pct_badge(result, active)
    return unless result

    pool_ratio = result[:pool_ratio]
    return unless pool_ratio

    pct = (pool_ratio * 100).round(0)
    color = if active
              pct >= 100 ? "text-green-300" : pct >= 80 ? "text-amber-300" : "text-red-300"
    else
              pct >= 100 ? "text-green-600 dark:text-green-400" :
              pct >= 80 ? "text-amber-600 dark:text-amber-400" :
              "text-red-600 dark:text-red-400"
    end
    span(class: "text-xs font-mono #{color}") { "#{pct}%" }
  end

  def spacer
    div(class: "flex-1") { }
  end

  def legend
    div(class: "hidden lg:flex items-center gap-3 text-[10px] text-gray-400 dark:text-gray-500") do
      FREQUENCY_LEGEND.each do |item|
        div(class: "flex items-center gap-1") do
          span(class: "w-2.5 h-2.5 rounded-sm #{item[:color]}") { }
          plain item[:label]
        end
      end
    end
  end

  def active_chip_classes
    "bg-gray-900 dark:bg-white text-white dark:text-gray-900"
  end

  def inactive_chip_classes
    "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 " \
    "hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors"
  end
end
