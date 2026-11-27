# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261127082422_create_tenant_setting_changes")

class CreateTenantSettingChangesTest < ActiveSupport::TestCase
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateTenantSettingChanges.new.migrate(direction) }
  end

  should "hold its default size to the app's" do
    assert_equal ComparisonConfig::DEFAULT_MIN_GROUP_SIZE, CreateTenantSettingChanges::DEFAULT_MIN_GROUP_SIZE
  end

  should "record each tenant's values today, dated from its creation, with the default for a size that isn't a whole number" do
    sydney = create(:tenant, time_zone: "Australia/Sydney", comparison_config: ComparisonConfig.new(min_group_size: 8))
    plain = create(:tenant)
    blank, decimal = create_list(:tenant, 2)
    Tenant.where(id: plain.id).update_all(comparison_config: {})
    Tenant.where(id: blank.id).update_all(%(comparison_config = '{"min_group_size": ""}'::jsonb))
    Tenant.where(id: decimal.id).update_all(%(comparison_config = '{"min_group_size": 4.5}'::jsonb))

    migrate(:down)
    migrate(:up)

    TenantSettingChange.reset_column_information
    rows = TenantSettingChange.unscoped.where(tenant_id: [ sydney, plain, blank, decimal ].map(&:id)).pluck(:tenant_id, :setting, :value, :changed_at)
    expected = [ [ sydney, "Australia/Sydney", "8" ], [ plain, "UTC", "5" ], [ blank, "UTC", "5" ], [ decimal, "UTC", "5" ] ].flat_map do |tenant, zone, size|
      created = tenant.reload.created_at
      [ [ tenant.id, "time_zone", zone, created ], [ tenant.id, "min_group_size", size, created ] ]
    end
    assert_equal expected.sort_by(&:to_s), rows.sort_by(&:to_s)
  ensure
    TenantSettingChange.reset_column_information
  end
end
