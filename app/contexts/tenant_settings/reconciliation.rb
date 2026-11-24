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
# @example
#   TenantSettings::Reconciliation.new(tenant).call
#   # => #<data Report added=0, removed=0, changed=1>
class TenantSettings::Reconciliation < TenantStreams::Reconciliation
  # @return [TenantSettings::Repository]
  def self.repository = TenantSettings::Repository.new

  private

  def held_in_table
    { settings: TenantSettings::Held.from(Tenant.lock("FOR SHARE").find(@tenant.id).org_graph_config) }
  end

  def held_in_stream(aggregate)
    { settings: { retention_years: aggregate.retention_years, scheduled_forgetting: aggregate.scheduled_forgetting?,
                  enabled_at: aggregate.enabled_at } }
  end

  def forgotten(_keys) = []

  def changed?(row, recorded)
    row[:retention_years] != recorded[:retention_years] || row[:scheduled_forgetting] != recorded[:scheduled_forgetting] ||
      (row[:scheduled_forgetting] && row[:enabled_at] && row[:enabled_at].to_i != recorded[:enabled_at].to_i)
  end

  def record_changed(aggregate, _key, row, _recorded) = aggregate.record_held(**row)
end
