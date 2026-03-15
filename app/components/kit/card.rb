# frozen_string_literal: true

# General-purpose card container.
#
# @example Basic card with title
#   render Components::Kit::Card.new(title: "Stats") do |card|
#     card.body { p { "Content here" } }
#   end
#
# @example Card with actions
#   render Components::Kit::Card.new(title: "User") do |card|
#     card.body { render_user_info }
#     card.actions { a(href: "/edit") { "Edit" } }
#   end
#
# @example Flush card (no body padding, for embedding tables)
#   render Components::Kit::Card.new(variant: :flush) do |card|
#     card.body { render_table }
#   end
#
class Components::Kit::Card < Components::Base
  VARIANTS = {
    default: "bg-white dark:bg-gray-800 rounded-lg shadow-xs border border-gray-200 dark:border-gray-700",
    flush: "bg-white dark:bg-gray-800 rounded-lg shadow-xs border border-gray-200 dark:border-gray-700 overflow-hidden"
  }.freeze

  # @param title [String, nil] optional card title
  # @param variant [Symbol] :default or :flush
  def initialize(title: nil, variant: :default)
    @title = title
    @variant = variant
  end

  def view_template
    div(class: VARIANTS[@variant]) do
      title_section if @title
      yield(self) if block_given?
    end
  end

  # Renders the card body content.
  #
  # @yield the body content
  def body(&block)
    padding = @variant == :flush ? "" : "px-6 pb-6"
    padding += " pt-6" unless @title
    div(class: padding, &block)
  end

  # Renders the card actions section.
  #
  # @yield the action buttons/links
  def actions(&block)
    div(class: "px-6 pb-6 flex justify-end gap-3", &block)
  end

  private

  def title_section
    div(class: "px-6 pt-6 pb-4") do
      h3(class: "text-base font-semibold text-gray-900 dark:text-white") { @title }
    end
  end
end
