# frozen_string_literal: true

# What the old keys of `tenants.org_graph_config` hold, in the terms the
# stream records: the JSON names the admin who turned the schedule on by
# account, where the stream names their person.
module TenantSettings::Held
  # @param config [OrgGraphConfig]
  # @return [Hash] keyword arguments for {TenantSettings::Aggregate#record_held}
  def self.from(config)
    {
      retention_years: config.retention_years, scheduled_forgetting: config.scheduled_forgetting,
      enabled_at: config.scheduled_forgetting_enabled_at,
      enabled_by_id: TenantUser.unscoped.where(id: config.scheduled_forgetting_enabled_by_id).pick(:person_id)
    }
  end
end
