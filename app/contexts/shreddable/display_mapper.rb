# frozen_string_literal: true

# Reads events for the RailsEventStore browser at /res. Each shreddable field
# shows as a placeholder: the browser renders event data as JSON, which a
# {Shreddable::Value} refuses, and an admin debugging a stream has no need of
# the value.
class Shreddable::DisplayMapper
  PLACEHOLDER = "[shreddable]"

  # @param inner [#records_to_events]
  def initialize(inner)
    @inner = inner
  end

  # @raise [NotImplementedError] the browser only reads
  def events_to_records(_events) = raise(NotImplementedError, "The event store browser only reads")

  # @param records [Array<RubyEventStore::Record>]
  # @return [Array<RubyEventStore::Event>]
  def records_to_events(records) = @inner.records_to_events(records).map { display(it) }

  private

  # A plain event, so the event class doesn't wrap the placeholder again.
  def display(event)
    fields = event.metadata[:shreddable] or return event

    RubyEventStore::Event.new(event_id: event.event_id,
                              metadata: event.metadata.to_h.merge(event_type: event.event_type),
                              data: event.data.merge(fields.keys.to_h { [ it.to_sym, PLACEHOLDER ] }))
  end
end
