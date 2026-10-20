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
# @example A compact inset panel inside another card
#   render Components::Kit::Card.new(variant: :inset, density: :compact) do |card|
#     card.body { render_bindings }
#   end
#
# @example An inset whose edge carries a state
#   render Components::Kit::Card.new(variant: :inset, edge: "border-warning") do |card|
#     card.body { render_gaps }
#   end
#
# @example A card that is a link
#   render Components::Kit::Card.new(title: "People", href: tenant_users_path) do |card|
#     card.body { "Invite and manage people." }
#   end
#
class Components::Kit::Card < Components::Base
  RAISED = "bg-default rounded-2xl shadow-raised border border-default"

  # The inset's edge is `border-default`: `border-subtle` and `bg-subtle` both match the card in dark
  VARIANTS = {
    default: RAISED,
    flush: "#{RAISED} overflow-hidden",
    inset: "bg-subtle rounded-md border border-default"
  }.freeze

  DENSITIES = {
    regular: { title: "px-6 pt-6 pb-4", body: "px-6 pb-6", top: "pt-6", actions: "px-6 pb-6", heading: "text-base" },
    compact: { title: "px-4 pt-3 pb-2", body: "px-4 pb-3", top: "pt-3", actions: "px-4 pb-3", heading: "text-sm" }
  }.freeze

  # `data-focused` lets a script mark the card the page is on with the same look as hover
  INTERACTIVE = "block transition-colors hover:border-emphasized hover:bg-hover " \
                "data-[focused=true]:border-emphasized focus-visible:outline-2 " \
                "focus-visible:outline-offset-2 focus-visible:outline-focus"

  # @param title [String, nil] optional card title
  # @param variant [Symbol] :default, :flush (no body padding) or :inset (a panel inside another surface)
  # @param density [Symbol] :regular or :compact (tighter padding, for panels and lists inside a card)
  # @param heading_level [Symbol] heading tag for the title (:h2..:h4) — set
  #   to keep the document outline sequential for the card's context
  # @param href [String, nil] render the card as a link to this URL; it can't then hold links or buttons
  # @param interactive [Boolean] give the card the hover and focus treatment without making it a link
  # @param edge [String, nil] a border colour utility in place of `border-default`
  # @param attributes [Hash] extra attributes for the root element, mixed with the card's own
  def initialize(title: nil, variant: :default, density: :regular, heading_level: :h3, href: nil,
                 interactive: false, edge: nil, **attributes)
    @title = title
    @variant = variant
    @density = DENSITIES.fetch(density)
    @heading_level = heading_level
    @href = href
    @interactive = interactive || href.present?
    @edge = edge
    @attributes = attributes
  end

  def view_template
    surface = VARIANTS.fetch(@variant)
    surface = surface.sub("border-default", @edge) if @edge
    attrs = mix({ class: [ surface, (INTERACTIVE if @interactive) ] }, @attributes)
    if @href
      a(href: @href, **attrs) { content { yield(self) if block_given? } }
    else
      div(**attrs) { content { yield(self) if block_given? } }
    end
  end

  # Renders the card body content.
  #
  # @yield the body content
  def body(&block)
    padding = if @variant == :flush then nil
    elsif @title then @density[:body]
    else "#{@density[:body]} #{@density[:top]}"
    end
    div(class: padding, &block)
  end

  # Renders the card actions section.
  #
  # @yield the action buttons/links
  def actions(&block)
    div(class: "#{@density[:actions]} flex justify-end gap-3", &block)
  end

  private

  def content
    title_section if @title
    yield
  end

  def title_section
    div(class: @density[:title]) do
      send(@heading_level, class: "#{@density[:heading]} font-semibold text-default") { @title }
    end
  end
end
