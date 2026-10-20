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
  # @param items [Array<Hash>] list of { term:, detail: } pairs
  # @param columns [Integer] number of grid columns (default 3)
  def initialize(items:, columns: 3)
    @items = items
    @columns = columns
  end

  def view_template
    dl(class: "grid grid-cols-1 sm:grid-cols-#{@columns} gap-4") do
      @items.each { |item| description_item(item) }
    end
  end

  private

  def description_item(item)
    div(class: "px-4 py-3 bg-subtle rounded-lg") do
      dt(class: "text-xs font-medium text-muted uppercase tracking-wide") do
        item[:term]
      end
      dd(class: "mt-1 text-xl font-semibold text-default") do
        item[:detail]
      end
    end
  end
end
