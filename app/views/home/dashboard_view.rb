# frozen_string_literal: true

# Home dashboard — a composable, role-aware grid of insight/action cards.
#
# The controller resolves the visible card instances (already ordered by
# urgency) via {Home::Registry}; this view renders one lazy Turbo Frame per
# instance. Each frame fetches its content from {HomeController#card}, so cards
# load independently and a slow card never blocks the page.
class Views::Home::DashboardView < Views::Base
  # @param card_instances [Array<Home::Card::Instance>] ordered, most-urgent first
  def initialize(card_instances:, user: nil, current_tenant: nil, tenants: [])
    @card_instances = card_instances
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "mx-auto max-w-5xl") do
        greeting
        if @card_instances.any?
          # Masonry (CSS multi-column) rather than a grid: a 2-column grid sizes
          # each row to its tallest card, so a short card beside the tall
          # activity feed leaves dead space and pushes later cards below the
          # fold. Columns pack cards vertically instead — the short cards stack
          # in one column alongside the feed.
          div(class: "columns-1 gap-4 md:columns-2") do
            @card_instances.each { |instance| card_frame(instance) }
          end
        else
          empty_state
        end
      end
    end
  end

  private

  # The way to give feedback unasked sits here, not on a card: the requests
  # card renders only when someone has asked, and feedback can't wait for that.
  def greeting
    h1(class: "mb-1 text-2xl font-semibold text-default") { "Home" }
    p(class: "mb-6 text-sm text-muted") do
      plain "Your next actions across #{product_name}. "
      a(href: evidence_hub_path(give: 1), class: "font-medium text-brand hover:underline",
        data: { testid: "home-give-feedback" }) { "Give someone feedback →" }
    end
  end

  # A lazy frame placeholder. Its content arrives from HomeController#card.
  def card_frame(instance)
    turbo_frame_tag(
      instance.dom_id,
      src: home_card_path(card: instance.card_key, key: instance.instance_key),
      loading: "lazy",
      class: "mb-4 block break-inside-avoid"
    ) do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "h-20 animate-pulse rounded bg-neutral-subtle")
        end
      end
    end
  end

  def empty_state
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-muted") do
          "Nothing needs your attention right now."
        end
      end
    end
  end
end
