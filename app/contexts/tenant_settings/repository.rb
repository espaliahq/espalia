# frozen_string_literal: true

# Loads and saves a tenant's settings, held in one stream per tenant:
# `TenantSettings`.
#
# @example
#   TenantSettings::Repository.new.with_settings { |settings| settings.set_retention_period(5) }
class TenantSettings::Repository < TenantStreams::Repository
  alias with_settings with_aggregate
  alias load_settings load_aggregate

  # Holds the stream's lock shared until the transaction ends, so no command
  # changes the settings while a forgetting that read them is going.
  # Commands take it exclusively, then the tenant row, and so does this, so
  # the two never deadlock.
  #
  # @return [void]
  def hold_shared
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock_shared(hashtextextended(?, 0))",
                                                   lock_key(current_tenant!) ])
    ActiveRecord::Base.connection.execute(sql)
  end

  private

  def new_aggregate = TenantSettings::Aggregate.new

  def stream_name(tenant) = EventStreamNaming.tenant_settings_stream(tenant:)
end
