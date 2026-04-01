# frozen_string_literal: true

# Horizontal tab bar for switching between capability categories in the assessment.
# Rendered inside the Turbo Frame so active state stays in sync on every frame load.
#
# Each tab is an <a> that targets the assessment-matrix Turbo Frame, causing a
# server-side re-render of the matrix with the selected category.
#
# On mobile, tabs wrap their text and fill the viewport width so all category
# names are fully visible without horizontal scrolling.
#
class Views::Assessments::CategoryTabs < Views::Base
  # @param categories [Array<Hash>] all category data from MatrixDataBuilder
  # @param scoring [Hash] primary scoring perspective output
  # @param active_category_id [String] currently selected category ID
  # @param assessment_id [String] UUID for building matrix URLs
  # @param context [Symbol] :self, :manager, or :alignment
  def initialize(categories:, scoring:, active_category_id:, assessment_id:, context: :self)
    @categories = categories
    @scoring = scoring
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
      href: matrix_assessment_path(@assessment_id, category: cat_id),
      data: { turbo_frame: "assessment-matrix" },
      class: tab_classes(active),
      aria_current: (active ? "page" : nil)
    ) do
      div(class: "flex items-center gap-1.5") do
        status_dot(result)
        span { category.name }
      end
      span(class: "text-[10px] #{active ? 'text-gray-600 dark:text-gray-300' : 'text-gray-400 dark:text-gray-500'}") do
        "#{progress[:rated]}/#{progress[:total]}"
      end
    end
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
end
