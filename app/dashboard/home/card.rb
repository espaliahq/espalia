# frozen_string_literal: true

# Base class for Home dashboard cards.
#
# A Card is a *descriptor* object (NOT a Phlex view): given an
# {AuthorizationContext} it decides whether it is visible to the viewer, how
# many instances to render (0..N), and the Phlex component that renders each
# instance's content.
#
# {Home::Registry} composes the visible instances across all registered cards,
# orders them by descending priority, and {Views::Home::DashboardView} renders
# one lazy Turbo Frame per instance. Each frame fetches its content from
# {HomeController#card}, so a slow card never blocks the page and each refreshes
# independently.
#
# Subclasses implement `.key`, `.audience?`, `.instances`, and
# `#render_content`. A card with no relevant data returns `[]` from
# `.instances` (renders nothing).
#
# Per-instance authorization for cards that surface another resource (e.g. a
# specific assessment cycle) MUST be enforced in `.audience?` / `#render_content`
# — the content endpoint is reachable directly by instance key, so the card is
# responsible for scoping every query to what `context` may see.
class Home::Card
  # Lightweight render descriptor for a single card instance.
  Instance = Data.define(:card_key, :instance_key, :priority, :title) do
    # Stable DOM id shared by the placeholder frame and its content response.
    # @return [String]
    def dom_id = "home-card-#{card_key}-#{instance_key}"
  end

  class << self
    # Stable identifier used in the card content route. Override.
    # @return [String]
    def key
      raise NotImplementedError, "#{name} must implement .key"
    end

    # Whether this card type is visible to the viewer.
    # @param _context [AuthorizationContext]
    # @return [Boolean]
    def audience?(_context) = false

    # Ordered, lightweight instances to render for the viewer (0..N).
    # Cheap existence/count queries only — never the heavy content.
    # @param _context [AuthorizationContext]
    # @return [Array<Home::Card::Instance>]
    def instances(_context) = []

    # Convenience for subclasses building an Instance carrying this card's key.
    # @return [Home::Card::Instance]
    def build_instance(instance_key: "default", priority: 0, title: nil)
      Instance.new(card_key: key, instance_key: instance_key.to_s, priority:, title:)
    end
  end

  # @param context [AuthorizationContext]
  def initialize(context)
    @context = context
  end

  attr_reader :context

  delegate :person, :user, :tenant_user, to: :context

  # The Phlex component rendered inside the lazy frame for one instance.
  # MUST scope all data to what `context` may see.
  # @param _instance_key [String]
  # @return [Phlex::HTML]
  def render_content(_instance_key)
    raise NotImplementedError, "#{self.class.name} must implement #render_content"
  end
end
