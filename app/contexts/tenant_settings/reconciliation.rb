# frozen_string_literal: true

# Records whatever the old keys of `tenants.org_graph_config` hold that the
# TenantSettings stream doesn't: the JSON is the truth.
#
# A tenant has one entry, held on both sides, since a stream with no events
# stands at the defaults. So a run only ever records a change, as already
# held and with no actor. A schedule turned off and on again in the JSON
# since is recorded as both. A run reads the JSON under the stream's lock and
# then the tenant row's, the order every command takes.
#
# A JSON with none of the keys holds nothing to record. c2b deletes them, and
# a rollback to this release must leave the stream as it stands, where reading
# the store model would record its defaults over a "never". A key present and
# null is a "never"; with any key present, a missing one reads as its default.
#
# @example
#   TenantSettings::Reconciliation.new(tenant).call
#   # => #<data Report added=0, removed=0, changed=1>
class TenantSettings::Reconciliation < TenantStreams::Reconciliation
  KEYS = %w[retention_years scheduled_forgetting scheduled_forgetting_enabled_at scheduled_forgetting_enabled_by_id].freeze

  # @return [TenantSettings::Repository]
  def self.repository = TenantSettings::Repository.new

  private

  def held_in_table
    tenant = Tenant.lock("FOR SHARE").find(@tenant.id)
    raw = tenant.read_attribute_before_type_cast("org_graph_config")
    raw = JSON.parse(raw) if raw.is_a?(String)
    return { settings: nil } unless raw.is_a?(Hash) && KEYS.any? { raw.key?(it) }

    { settings: TenantSettings::Held.from(tenant.org_graph_config) }
  end

  def held_in_stream(aggregate)
    { settings: { retention_years: aggregate.retention_years, scheduled_forgetting: aggregate.scheduled_forgetting?,
                  enabled_at: aggregate.enabled_at } }
  end

  def forgotten(_keys) = []

  def changed?(row, recorded)
    return false if row.nil?

    row[:retention_years] != recorded[:retention_years] || row[:scheduled_forgetting] != recorded[:scheduled_forgetting] ||
      (row[:scheduled_forgetting] && row[:enabled_at] && !TenantSettings::Aggregate.same_enable?(row[:enabled_at], recorded[:enabled_at]))
  end

  def record_changed(aggregate, _key, row, _recorded) = aggregate.record_held(**row)
end
