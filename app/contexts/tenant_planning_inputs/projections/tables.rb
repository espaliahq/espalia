# frozen_string_literal: true

# Synchronous projection of the TenantPlanningInputs stream into the five
# tables plans are priced from: pay_bands, exchange_rates,
# reference_currencies, budget_lines and planning_rule_defaults. It also
# writes `tenants.pay_bands_changed_at`, the "as of" every plan's cost reads.
#
# The only writer of those tables and that column. It writes statements, not
# records, so no model callback runs. Each row keeps the id its event
# carries, so a rebuild keeps every id a tool or a URL holds.
#
class TenantPlanningInputs::Projections::Tables
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "tenant_planning_inputs/tables"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  TABLE_OF = TenantPlanningInputs::Aggregate::WRITES.flat_map { |table, events| events.values.compact.map { [ it, table ] } }
                                                    .to_h.merge(TenantPlanningInputs::Events::PayBandsReordered => :pay_bands).freeze
  private_constant :TABLE_OF

  REMOVALS = TenantPlanningInputs::Aggregate::WRITES.values.filter_map { it[:remove] }.freeze
  private_constant :REMOVALS

  # Runs a read a write plans from, refused while this projection rebuilds,
  # as the tables are then part written.
  #
  # @yield while no rebuild can start
  # @return [Object] the block's value
  # @raise [ProjectionVersion::Rebuilding] while a rebuild holds the tables
  def self.unless_rebuilding(&) = ProjectionVersion.unless_rebuilding(PROJECTION_NAME, &)

  # @return [Array<Class>]
  def self.handled_events
    TABLE_OF.keys
  end

  # Writes the five tables, and the bands' stamp once a band event has set
  # one, as the stream holds them, deleting rather than truncating so readers
  # never wait on a table lock. It holds the stream's lock in one
  # transaction, so a reader sees the old rows or the new, never an empty
  # table, and no command lands between the read and the write.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      TenantPlanningInputs::Repository.new.reading_locked do |inputs|
        TenantPlanningInputs::Rows::TABLES.each_key do |table|
          model = TenantPlanningInputs::Rows.model(table)
          model.where(tenant_id: tenant.id).delete_all
          rows = inputs.entries(table).map { |id, entry| row_for(tenant, table, id, entry) }
          model.insert_all!(rows, record_timestamps: false) if rows.any?
        end
        Tenant.where(id: tenant.id).update_all(pay_bands_changed_at: inputs.bands_changed_at) if inputs.bands_changed_at
      end
    end
  end

  # @param tenant [Tenant]
  # @param table [Symbol] one of {TenantPlanningInputs::Rows::TABLES}
  # @param id [String]
  # @param entry [TenantPlanningInputs::Aggregate::Entry]
  # @return [Hash{String => Object}] the row as the table holds it. `updated_by_id` is the previous
  #   release's: clearing it tells reconcile which release last changed the row.
  def self.row_for(tenant, table, id, entry)
    TenantPlanningInputs::Rows.complete(table, entry.row).merge("id" => id, "tenant_id" => tenant.id, "created_at" => entry.created_at,
                    "updated_at" => entry.updated_at, "updated_by_person_id" => entry.updated_by_person_id,
                    "updated_by_id" => nil)
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    # The reset already wrote where the stream ends. Replaying its events
    # again would pass through earlier states a stopped replay could leave.
    return if Projections::Replayer.replay_mode?

    tenant = ActsAsTenant.current_tenant
    tenant = Tenant.find(event.metadata[:tenant_id]) unless tenant&.id == event.metadata[:tenant_id]
    ActsAsTenant.with_tenant(tenant) { write(tenant, event) }
  end

  private

  def write(tenant, event)
    table = TABLE_OF.fetch(event.class)
    data = event.data
    model = TenantPlanningInputs::Rows.model(table)
    if REMOVALS.include?(event.class)
      model.where(tenant_id: tenant.id, id: data[:id]).delete_all
    elsif data[:row]
      upsert(tenant, table, data)
    end
    return unless table == :pay_bands

    reorder(tenant, data[:order]) if data[:order]
    Tenant.where(id: tenant.id).update_all(pay_bands_changed_at: data[:bands_changed_at]) if data[:bands_changed_at]
  end

  # A row reconcile records may already be in the table, so a write is an
  # upsert that keeps the row's created_at.
  def upsert(tenant, table, data)
    entry = TenantPlanningInputs::Aggregate::Entry.new(
      row: data[:row].deep_stringify_keys, created_at: data[:created_at] || data[:at], updated_at: data[:at],
      updated_by_person_id: data[:changed_by_id] || data[:last_changed_by_id]
    )
    row = self.class.row_for(tenant, table, data[:id], entry)
    TenantPlanningInputs::Rows.model(table).upsert_all([ row ], unique_by: :id, record_timestamps: false,
                              update_only: row.keys - %w[id tenant_id created_at])
  end

  def reorder(tenant, order)
    PayBand.where(tenant_id: tenant.id, id: order)
           .update_all([ "position = array_position(ARRAY[?]::uuid[], id)", order ])
  end
end
