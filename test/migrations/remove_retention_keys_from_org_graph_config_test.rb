# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261125043511_remove_retention_keys_from_org_graph_config")

class RemoveRetentionKeysFromOrgGraphConfigTest < ActiveSupport::TestCase
  def stored(config)
    tenant = create(:tenant)
    Tenant.where(id: tenant.id).update_all([ "org_graph_config = ?::jsonb", config.to_json ])
    tenant
  end

  def config_of(tenant) = JSON.parse(Tenant.connection.select_value(Tenant.where(id: tenant.id).select("org_graph_config::text").to_sql))

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { RemoveRetentionKeysFromOrgGraphConfig.new.migrate(direction) }
  end

  should "remove the retention keys and keep the tenant's other settings" do
    tenant = stored({ "staleness_days" => 30, "retention_years" => nil, "scheduled_forgetting" => true,
                      "scheduled_forgetting_enabled_at" => "2026-11-02T09:00:00.000Z",
                      "scheduled_forgetting_enabled_by_id" => "a-1" })

    migrate(:up)

    assert_equal({ "staleness_days" => 30 }, config_of(tenant))
  end

  should "leave a config that holds none of them alone, and change nothing on the way down" do
    untouched = stored({ "staleness_days" => 45 })

    migrate(:up)
    migrate(:down)

    assert_equal({ "staleness_days" => 45 }, config_of(untouched))
  end
end
