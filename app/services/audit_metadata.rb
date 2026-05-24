# frozen_string_literal: true

# Thread-local context that records *who* and *how* triggered a write.
# Read by {Operations::Base#call} (and the HRIS adapter) to stamp every
# RailsEventStore event with `acting_via` and, when applicable,
# `client_application_id`, so we can attribute writes back to the web UI,
# a specific MCP client, or an HRIS sync.
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
  ACTING_VIA = %i[web mcp hris].freeze

  STORE_KEY = :audit_metadata
  private_constant :STORE_KEY

  module_function

  # Block form. Restores any prior context on exit so nested calls
  # (e.g. an HRIS sync that invokes an Operation) behave predictably.
  #
  # @param acting_via [Symbol] :web | :mcp | :hris
  # @param client_application_id [String, nil] the Doorkeeper application
  #   uuid when acting_via == :mcp
  def with(acting_via:, client_application_id: nil)
    previous = Thread.current[STORE_KEY]
    Thread.current[STORE_KEY] = build(acting_via, client_application_id)
    yield
  ensure
    Thread.current[STORE_KEY] = previous
  end

  # Request-lifecycle form. Pair with `clear!` in an `after_action` /
  # `ensure` so the next request on this worker thread starts clean.
  def seed!(acting_via:, client_application_id: nil)
    Thread.current[STORE_KEY] = build(acting_via, client_application_id)
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

  def build(acting_via, client_application_id)
    raise ArgumentError, "unknown acting_via #{acting_via.inspect}" unless ACTING_VIA.include?(acting_via)

    hash = { acting_via: acting_via }
    hash[:client_application_id] = client_application_id if client_application_id
    hash
  end
  private_class_method :build
end
