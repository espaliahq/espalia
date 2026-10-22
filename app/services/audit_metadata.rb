# frozen_string_literal: true

# Thread-local context that records *who*, *how*, and *as part of which
# logical operation* triggered a write. Read by {Operations::Base#call}
# (and the HRIS adapter) to stamp every RailsEventStore event with
# provenance metadata, so we can attribute any write back to the web UI,
# a specific MCP client, or an HRIS sync — and correlate every event a
# single request/operation produced.
#
# Five provenance fields, all carried in RES *metadata* (never payload):
#   - `acting_via` — :web | :mcp | :hris | :slack | :feedback_exchange |
#     :system (the surface; :feedback_exchange is feedback imported from a
#     peer system, written as its real author; :system is a scheduled job
#     acting on its own, e.g. the evidence-request reminder sweep).
#   - `actor_id` — the Person uuid who triggered the write, when there is
#     one (nil for system-driven HRIS syncs). While a tenant admin is
#     impersonating another user, this is the *impersonated* Person — the
#     write is attributed as the target would have produced it.
#   - `impersonator_id` — the *real* Person driving the request when an
#     impersonation session is active (nil otherwise — e.g. an admin with
#     no linked Person). Pairs with `actor_id` so an impersonated write is
#     traceable to the human who actually clicked. Impersonation is
#     read-only today, so this is belt-and-suspenders: if a write ever
#     slips past the read-only guards, both identities are on the event.
#   - `impersonation_active` — `true` while impersonating. Unlike
#     `impersonator_id` this never depends on Person presence, so it is the
#     authoritative signal {Operations::Base}'s read-only backstop consults.
#   - `client_application_id` — the Doorkeeper application uuid (MCP only).
#   - `correlation_id` — a per-request / per-sync id shared by every event
#     the boundary produced, so a whole logical operation can be traced.
#
# This is the universal *provenance* layer. When the actor is also a
# first-class *domain fact* a read model surfaces (e.g. which manager
# rated you), model it ADDITIONALLY as an explicit event payload field —
# see docs/guidelines/event-sourcing.md.
#
# Two seeding styles, both writing to the same Thread.current slot:
#   - `with(...)` block form — for background jobs / scripts that bound
#     their own audit window.
#   - `seed!` / `clear!` — for controllers, called from before/after
#     actions (a request is one logical audit window).
#
# `wrap_event_store(&block)` is the consumer-side helper: it wraps any
# block with `Rails.configuration.event_store.with_metadata` IF context
# is set, and is a transparent no-op otherwise. This keeps Operations
# safe to call from tests and rake tasks that never seed metadata.
module AuditMetadata
  ACTING_VIA = %i[web mcp hris slack feedback_exchange system].freeze

  STORE_KEY = :audit_metadata
  private_constant :STORE_KEY

  module_function

  # Block form. Restores any prior context on exit so nested calls
  # (e.g. an HRIS sync that invokes an Operation) behave predictably.
  #
  # @param acting_via [Symbol] one of {ACTING_VIA}
  # @param actor_id [String, nil] uuid of the Person triggering the write
  # @param impersonator_id [String, nil] uuid of the real Person when an
  #   impersonation session is active
  # @param impersonation_active [Boolean] whether an impersonation session
  #   is active — the authoritative signal for the read-only backstop,
  #   independent of whether the real admin has a linked Person (so the
  #   guard holds even when `impersonator_id` is nil)
  # @param client_application_id [String, nil] the Doorkeeper application
  #   uuid when acting_via == :mcp
  # @param correlation_id [String, nil] id shared by every event this
  #   request/operation produces (a request id, or a sync-run id)
  def with(acting_via:, actor_id: nil, impersonator_id: nil, impersonation_active: false,
           client_application_id: nil, correlation_id: nil)
    previous = Thread.current[STORE_KEY]
    Thread.current[STORE_KEY] =
      build(acting_via, actor_id, impersonator_id, impersonation_active, client_application_id, correlation_id)
    yield
  ensure
    Thread.current[STORE_KEY] = previous
  end

  # Request-lifecycle form. Pair with `clear!` in an `after_action` /
  # `ensure` so the next request on this worker thread starts clean.
  def seed!(acting_via:, actor_id: nil, impersonator_id: nil, impersonation_active: false,
            client_application_id: nil, correlation_id: nil)
    Thread.current[STORE_KEY] =
      build(acting_via, actor_id, impersonator_id, impersonation_active, client_application_id, correlation_id)
  end

  def clear!
    Thread.current[STORE_KEY] = nil
  end

  # @return [Hash] the current audit hash, or `{}` if nothing is seeded.
  def current
    Thread.current[STORE_KEY] || {}
  end

  # Wraps `block` so any events published inside it carry the current
  # audit metadata. No-op when nothing is seeded — keeps existing tests
  # and rake tasks (which don't seed) from acquiring spurious metadata.
  def wrap_event_store(&block)
    metadata = current
    return yield if metadata.empty?

    Rails.configuration.event_store.with_metadata(serialize(metadata), &block)
  end

  # ruby_event_store::Metadata only accepts String / Integer / Float /
  # Date / Time / Bool / nil / Hash / Array values — Symbols would raise
  # ArgumentError at publish time. We keep `acting_via` as a Symbol in
  # the thread-local for caller ergonomics and stringify just before
  # handing it to the event store.
  def serialize(metadata)
    metadata.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }
  end

  def build(acting_via, actor_id, impersonator_id, impersonation_active, client_application_id, correlation_id)
    raise ArgumentError, "unknown acting_via #{acting_via.inspect}" unless ACTING_VIA.include?(acting_via)

    hash = { acting_via: acting_via }
    hash[:actor_id] = actor_id if actor_id
    hash[:impersonator_id] = impersonator_id if impersonator_id
    hash[:impersonation_active] = true if impersonation_active
    hash[:client_application_id] = client_application_id if client_application_id
    hash[:correlation_id] = correlation_id if correlation_id
    hash
  end
  private_class_method :build
end
