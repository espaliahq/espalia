# frozen_string_literal: true

# What a page or panel shows when it has nothing to list yet: a dashed box
# with a title, an optional line of help and an optional way to start.
#
# @example An index page
#   render Components::Kit::EmptyState.new(title: "No frameworks yet") do |empty|
#     empty.action { a(href: new_framework_path) { "Create a framework" } }
#     "A framework sets out the roles, levels and capabilities people are rated on."
#   end
#
# @example A side panel
#   render Components::Kit::EmptyState.new(title: "No activity yet", size: :panel)
#
class Components::Kit::EmptyState < Components::Base
  SIZES = {
    page: "p-10",
    panel: "p-4"
  }.freeze

  TITLE_SIZES = {
    page: "text-base",
    panel: "text-sm"
  }.freeze

  BODY_SIZES = {
    page: "mt-1 text-sm",
    panel: "mt-1 text-xs"
  }.freeze

  ACTION_SIZES = {
    page: "mt-4",
    panel: "mt-2"
  }.freeze

  BASE = "rounded-lg border border-dashed border-emphasized text-center"

  # @param title [String] what's missing, in a few words
  # @param size [Symbol] :page for a page or index, :panel for a side panel or card
  def initialize(title:, size: :page)
    @title = title
    @size = size
  end

  def view_template(&block)
    div(class: [ BASE, SIZES.fetch(@size) ]) do
      p(class: [ "font-semibold text-default", TITLE_SIZES.fetch(@size) ]) { @title }
      div(class: [ "text-muted", BODY_SIZES.fetch(@size) ]) { yield(self) } if block
      actions if @action_block
    end
  end

  # A link or button to start filling the list. Call it inside the block.
  #
  # @yield the action
  def action(&block)
    @action_block = block
  end

  private

  def actions
    div(class: [ "flex flex-wrap items-center justify-center gap-3", ACTION_SIZES.fetch(@size) ]) do
      @action_block.call
    end
  end
end
