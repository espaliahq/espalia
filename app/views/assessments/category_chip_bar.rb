# frozen_string_literal: true

# Horizontal chip bar for category navigation in the card-based assessment view.
#
# Each chip is an anchor link that smooth-scrolls to the category section.
# Carries `id="category-tabs"` for Turbo Stream replacement by rating
# controllers.
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
        class: "flex flex-wrap items-center gap-2 mb-6") do
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
    pct = result ? (result[:pool_ratio] || 0.0) : nil
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
      plain category.name
      if pct
        pct_display = (pct * 100).round(0)
        span(class: "text-xs font-mono #{pct_color(pct)}") { "#{pct_display}%" }
      end
    end
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

  def pct_color(ratio)
    if ratio >= 1.0
      "text-green-300 dark:text-green-600"
    elsif ratio >= 0.8
      "text-amber-300 dark:text-amber-600"
    else
      "text-red-300 dark:text-red-600"
    end
  end
end
