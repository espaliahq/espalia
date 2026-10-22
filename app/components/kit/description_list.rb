# frozen_string_literal: true

# Term/detail pairs in a responsive grid.
#
# @example
#   render Components::Kit::DescriptionList.new(items: [
#     { term: "Roles", detail: "11" },
#     { term: "Capabilities", detail: "40" }
#   ])
#
class Components::Kit::DescriptionList < Components::Base
  # Literal class names: Tailwind's JIT cannot see an interpolated one, so
  # `sm:grid-cols-#{n}` was never generated and the grid stayed one column wide.
  COLUMN_CLASSES = { 1 => "sm:grid-cols-1", 2 => "sm:grid-cols-2", 3 => "sm:grid-cols-3", 4 => "sm:grid-cols-4" }.freeze

  # @param items [Array<Hash>] list of { term:, detail: } pairs
  # @param columns [Integer] number of grid columns (default 3)
  def initialize(items:, columns: 3)
    @items = items
    @columns = columns
  end

  def view_template
    dl(class: "grid grid-cols-1 #{COLUMN_CLASSES.fetch(@columns)} gap-4") do
      @items.each { |item| description_item(item) }
    end
  end

  private

  def description_item(item)
    div(class: "min-w-0 px-4 py-3 bg-gray-50 dark:bg-gray-800/50 rounded-lg") do
      dt(class: "text-xs font-medium text-gray-600 dark:text-gray-300 uppercase tracking-wide") do
        item[:term]
      end
      dd(class: "mt-1 text-xl font-semibold text-gray-900 dark:text-white [overflow-wrap:anywhere]") do
        item[:detail]
      end
    end
  end
end
