# frozen_string_literal: true

# Seals the plan and scenario names stored in clear before names became
# shreddable ([#209](https://github.com/espaliahq/espalia/issues/209)). It is
# the one sanctioned rewrite of stored events: see "The one rewrite" in
# docs/team-planning/shreddable-fields-design.md before copying it.
#
# Each record keeps its id, type, order and timestamps, and every byte but
# the name fields and the `shreddable` entries in its metadata. A deleted
# plan's names are sealed under a key that is thrown away, so they read as
# removed. A record already sealed is left alone, so a second run changes
# nothing.
class TeamPlanning::NameSealing
  EVENT_TYPES = [
    TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanRenamed, TeamPlanning::Events::ScenarioForked
  ].freeze
  PROJECTIONS = [ TeamPlanning::Projections::Plans, TeamPlanning::Projections::Scenarios ].freeze

  # The stored row. RES keeps its own model private.
  class StoredEvent < ActiveRecord::Base
    self.table_name = "event_store_events"
  end

  # Mints keys as the store does, but gives a deleted plan a key nobody
  # keeps, so its names read as removed.
  class ThrowawayForDestroyed
    def initialize(store = PlanKeyStore.new) = @store = store

    def create(identifier, cipher: PlanKeyStore::DEFAULT_CIPHER)
      @store.create(identifier, cipher:)
    rescue PlanKeyStore::Destroyed
      RubyEventStore::Mappers::EncryptionKey.new(cipher:, key: SecureRandom.random_bytes(32))
    end
  end

  # @param tenant [Tenant]
  def initialize(tenant)
    @tenant = tenant
    @default = Shreddable::Mapper.json_client_default
    @sealing = Shreddable::Mapper.new(@default, key_store: ThrowawayForDestroyed.new)
  end

  # @return [Hash{String => Integer}] how many records of each type would be sealed
  def dry_run = count(unsealed)

  # Seals every record still in clear, then rebuilds the plans and scenarios
  # read models from them, all in one transaction.
  #
  # @return [Hash{String => Integer}] how many records of each type were sealed
  def seal!
    ActsAsTenant.with_tenant(@tenant) do
      StoredEvent.transaction do
        rows = unsealed
        rows.each { |row| row.update_columns(**sealed(row)) }
        PROJECTIONS.each { rebuild(it) } if rows.any?
        count(rows)
      end
    end
  end

  private

  def unsealed
    StoredEvent.where(event_type: EVENT_TYPES.map(&:name)).order(:id).select do |row|
      metadata = JSON.parse(row.metadata)
      metadata["tenant_id"] == @tenant.id && !metadata.key?("shreddable")
    end
  end

  def count(rows) = EVENT_TYPES.to_h { |type| [ type.name, rows.count { it.event_type == type.name } ] }

  # Seals the event as a new write would, then copies back only what sealing
  # changes, so every other byte of the stored JSON stays as it was.
  def sealed(row)
    data, metadata = JSON.parse(row.data), JSON.parse(row.metadata)
    written = @sealing.events_to_records([ event(row) ]).sole.serialize(JSON)
    new_data, new_metadata = JSON.parse(written.data), JSON.parse(written.metadata)

    new_metadata["shreddable"].each_key { data[it] = new_data.fetch(it) }
    metadata["shreddable"] = new_metadata["shreddable"]
    metadata["types"]["metadata"]["shreddable"] = new_metadata["types"]["metadata"]["shreddable"]
    { data: JSON.generate(data), metadata: JSON.generate(metadata) }
  end

  def event(row)
    record = RubyEventStore::SerializedRecord.new(
      event_id: row.event_id, event_type: row.event_type, data: row.data, metadata: row.metadata,
      timestamp: row.created_at.iso8601(6), valid_at: (row.valid_at || row.created_at).iso8601(6)
    )
    @default.records_to_events([ record.deserialize(JSON) ]).sole
  end

  def rebuild(projection)
    projection.reset!(tenant: @tenant)
    Projections::Replayer.replay(projection_class: projection, tenant: @tenant)
  end
end
