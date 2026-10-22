# frozen_string_literal: true

# Horizontal chip bar for category navigation in the card-based assessment view.
#
# Each chip is an anchor link that smooth-scrolls to the category section,
# carrying a pass/fail status dot and optional % score. Carries
# `id="category-tabs"` for Turbo Stream replacement by rating controllers.
#
class Views::Assessments::CategoryChipBar < Views::Base
  include Views::Assessments::Concerns::RatedCount
  include Views::Assessments::Concerns::ScoreScale

  # aria-current carries the active chip, so category_nav_controller moves it with the attribute alone.
  CHIP_CLASSES = "group inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm font-medium " \
                 "bg-neutral-subtle text-muted not-aria-[current=page]:hover:bg-neutral-muted transition-colors " \
                 "aria-[current=page]:bg-neutral-strong aria-[current=page]:text-inverse"

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
    end
  end

  private

  def all_chip
    total = @categories.sum { |c| c[:capabilities].size }
    a(
      href: "#",
      class: CHIP_CLASSES,
      aria: { current: ("page" if @active_category_id.nil?) }.compact,
      data: { all_chip: "true", action: "click->category-nav#scrollToTop" }
    ) do
      plain "All"
      span(class: "text-xs font-mono font-normal") { total.to_s }
    end
  end

  def category_chip(cat_data)
    category = cat_data[:category]
    result = @scoring.dig(:category_scores, category.category_id)
    active = category.category_id == @active_category_id

    attrs = {
      href: "#category-#{category.category_id}",
      class: CHIP_CLASSES,
      data: { category_id: category.category_id,
              action: "click->category-nav#scrollTo" }
    }
    attrs[:aria] = { current: "page" } if active
    unlocked = category_unlocked?(cat_data)
    a(**attrs) do
      status_dot(result) if unlocked
      plain category.name
      pct_badge(result) if unlocked
      rated_count_chip(cat_data)
    end
  end

  # The category's state as a dot — the same tone the header's number
  # wears. Only called once the category is unlocked, which already
  # settled that there is a score to colour.
  def status_dot(result)
    span(
      class: "w-2 h-2 rounded-full #{tone_bar(result[:state])} shrink-0",
      data: { category_status: result[:state] }
    ) { }
  end

  # The category's score, once enough of its assessed-level cells are rated
  # to mean something (the hero's own unlock rule).
  def pct_badge(result)
    span(class: "text-xs font-mono tabular-nums #{tone_text(result[:state])} " \
                "group-aria-[current=page]:text-white/80 dark:group-aria-[current=page]:text-gray-900/80") do
      "#{percent(result[:score])}%"
    end
  end

  # Tiny "3/24" count tucked inside the chip — desktop only so narrow
  # viewports keep chips compact and horizontally scrollable. Hidden when
  # the category has no cells. The active chip lifts contrast against its
  # dark fill (text-gray-300 at 10px was barely legible).
  def rated_count_chip(cat_data)
    counts = category_rated_count(cat_data, @context)
    return if counts[:total].zero?

    span(class: "hidden lg:inline text-[10px] font-mono tabular-nums text-gray-600 dark:text-gray-300 " \
                "group-aria-[current=page]:text-white/70 dark:group-aria-[current=page]:text-gray-900/70") do
      "#{counts[:rated]}/#{counts[:total]}"
    end
  end

  # The hero's coverage rule at category grain: a score only shows once at
  # least half of the category's assessed-level cells carry a rating.
  # Must stay in step with CategoryIndicators#unlocked? — the chip and the
  # section header are the same category, and a chip showing a red 0% for
  # a category the header declines to score is the worse of the two lies.
  def category_unlocked?(cat_data)
    result = @scoring.dig(:category_scores, cat_data[:category].category_id)
    return false unless result && result[:scorable]

    counts = category_rated_count(cat_data, @context)
    return true if counts[:total].zero?

    counts[:rated] >= (counts[:total] * Views::Assessments::HeroSummary::COVERAGE_UNLOCK_THRESHOLD).ceil
  end
end
