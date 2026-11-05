# frozen_string_literal: true

# Every version of a framework that was published, newest first, read from
# its `FrameworkVersionPublished` events. The events, not
# `framework_publications`: that table only records publishes made through
# the publication job, which began after the first versions shipped.
#
# @example
#   Frameworks::PublishedVersions.new(framework_id: id).call.first.version
class Frameworks::PublishedVersions
  Version = Data.define(:version, :published_at, :published_by_id)

  # @param framework_id [String]
  # @param event_store [RailsEventStore::Client]
  def initialize(framework_id:, event_store: Rails.configuration.event_store)
    @framework_id = framework_id
    @event_store = event_store
  end

  # @return [Array<Version>]
  def call
    @event_store.read.stream(EventStreamNaming.framework_stream(@framework_id))
      .of_type([ Frameworks::Events::FrameworkVersionPublished ]).backward.to_a.map do |event|
        Version.new(
          version: event.data[:version],
          published_at: event.metadata[:timestamp],
          published_by_id: person_id(event.data[:published_by]) || person_id(event.metadata[:actor_id])
        )
      end
  end

  private

  # The seed and benchmark tasks publish as "seed" / "bench", not a person.
  def person_id(value)
    value.to_s.match?(Frameworks::ActivityFeedQuery::UUID_FORMAT) ? value : nil
  end
end
