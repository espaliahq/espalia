# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261127082422_create_tenant_setting_changes")

class CreateTenantSettingChangesTest < ActiveSupport::TestCase
  STORED_SIZES = { "a whole number" => 8, "a decimal" => 4.5, "a decimal string" => "4.9", "a leading zero" => "08",
                   "a blank" => "", "a word" => "five", "a negative" => -3, "a null" => nil }.freeze

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateTenantSettingChanges.new.migrate(direction) }
  end

  def store(tenant, config)
    Tenant.where(id: tenant.id).update_all([ "comparison_config = ?::jsonb", config.to_json ])
  end

  should "hold its sizes to the app's" do
    assert_equal ComparisonConfig::DEFAULT_MIN_GROUP_SIZE, CreateTenantSettingChanges::DEFAULT_MIN_GROUP_SIZE
    assert_equal ComparisonConfig::LOWEST_MIN_GROUP_SIZE, CreateTenantSettingChanges::LOWEST_MIN_GROUP_SIZE
  end

  should "record each tenant's values today, dated from its creation, with the floor the app reads from each stored size" do
    staged = STORED_SIZES.to_h { |name, size| [ name, create(:tenant).tap { store(it, { "min_group_size" => size }) } ] }
    staged["no size"] = create(:tenant).tap { store(it, {}) }
    sydney = create(:tenant, time_zone: "Australia/Sydney")

    migrate(:down)
    migrate(:up)

    TenantSettingChange.reset_column_information
    recorded = TenantSettingChange.unscoped.where(tenant_id: [ *staged.values, sydney ].map(&:id)).to_a
    staged.merge("Sydney" => sydney).each do |name, tenant|
      tenant.reload
      rows = recorded.select { it.tenant_id == tenant.id }.to_h { [ it.setting, it ] }
      app_floor = ComparisonConfig.floor_for(tenant.comparison_config.min_group_size).to_s

      assert_equal [ app_floor, tenant.time_zone ], rows.values_at("min_group_size", "time_zone").map(&:value), name
      assert_equal [ tenant.created_at ] * 2, rows.values.map(&:changed_at), name
    end
  ensure
    TenantSettingChange.reset_column_information
  end
end
