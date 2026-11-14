# frozen_string_literal: true

# Synchronous handler: once a tenant is fed from the Org Graph, each change
# to a person's title, level, manager or employment reconciles their Person
# Development stream through {OrgGraph::PersonDevelopmentFeed}.
#
# Each reconcile runs in a savepoint, so a command the domain refuses rolls
# back alone and never fails the write that triggered it. The refusal is
# logged and counted under `errors`.
#
# NEVER replayed on projection rebuild: it dispatches person commands. It is
# subscribed, not registered in `Projections::Registry::REPLAYABLE`.
#
class OrgGraph::SyncHandlers::PersonDevelopmentFeed
  TALLY_KEY = :org_graph_person_development_feed_tally

  # @return [Array<Class>]
  def self.handled_events
    [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::TitleChanged, OrgGraph::Events::LevelChanged,
      OrgGraph::Events::ManagerChanged, OrgGraph::Events::PersonLeft, OrgGraph::Events::PersonReturned ]
  end

  # Counts what the handler does while the block runs, on this thread.
  #
  # @yield
  # @return [Hash{Symbol => Integer}] a count for each kind in
  #   {OrgGraph::PersonDevelopmentFeed::KINDS} that happened, and `errors`
  def self.tally
    previous = Thread.current[TALLY_KEY]
    counts = Thread.current[TALLY_KEY] = Hash.new(0)
    yield
    counts.to_h
  ensure
    Thread.current[TALLY_KEY] = previous
  end

  # @param changes [Array<Symbol>]
  def self.count(changes)
    counts = Thread.current[TALLY_KEY] or return
    changes.each { counts[it] += 1 }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    tenant = Tenant.find(event.metadata[:tenant_id])
    return unless tenant.person_development_fed?

    person_id = event.data[:person_id]
    ActsAsTenant.with_tenant(tenant) do
      with_provenance do
        changes = ActiveRecord::Base.transaction(requires_new: true) do
          OrgGraph::PersonDevelopmentFeed.new(tenant).reconcile(person_id)
        end
        self.class.count(changes)
      end
    end
  rescue => e
    Rails.logger.warn("[org_graph] person development feed refused person=#{person_id}: #{e.class}: #{e.message}")
    self.class.count([ :errors ])
  end

  private

  def with_provenance(&)
    return AuditMetadata.wrap_event_store(&) if AuditMetadata.current.any?

    AuditMetadata.with(acting_via: :system) { AuditMetadata.wrap_event_store(&) }
  end
end
