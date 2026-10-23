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
  # Whole class names: Tailwind builds only classes it finds spelled out in the source.
  COLUMNS = {
    1 => "sm:grid-cols-1",
    2 => "sm:grid-cols-2",
    3 => "sm:grid-cols-3",
    4 => "sm:grid-cols-4"
  }.freeze

  # @param items [Array<Hash>] list of { term:, detail: } pairs
  # @param columns [Integer] number of grid columns from `sm` up, 1–4 (default 3)
  # @raise [ArgumentError] for any other column count
  def initialize(items:, columns: 3)
    raise ArgumentError, "columns must be 1–#{COLUMNS.size}, got #{columns.inspect}" unless COLUMNS.key?(columns)

    @items = items
    @columns = columns
  end

  def view_template
    dl(class: "grid grid-cols-1 #{COLUMNS.fetch(@columns)} gap-4") do
      @items.each { |item| description_item(item) }
    end
  end

  private

  def description_item(item)
    div(class: "min-w-0 px-4 py-3 bg-subtle rounded-lg") do
      dt(class: "text-xs font-medium text-muted uppercase tracking-wide") do
        item[:term]
      end
      dd(class: "mt-1 text-xl font-semibold text-default [overflow-wrap:anywhere]") do
        item[:detail]
      end
    end
  end
end
