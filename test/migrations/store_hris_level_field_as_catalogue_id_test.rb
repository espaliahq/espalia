# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261113000002_store_hris_level_field_as_catalogue_id")

class StoreHrisLevelFieldAsCatalogueIdTest < ActiveSupport::TestCase
  def stored(config)
    tenant = create(:tenant)
    StoreHrisLevelFieldAsCatalogueId::TenantRow.where(id: tenant.id).update_all(hris_config: config)
    tenant
  end

  def config_of(tenant) = StoreHrisLevelFieldAsCatalogueId::TenantRow.find(tenant.id).hris_config

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { StoreHrisLevelFieldAsCatalogueId.new.migrate(direction) }
  end

  should "give a bare custom-column id its path, keeping the rest of the config" do
    bare = stored({ "provider" => "hibob", "sync_enabled" => true, "level_field_id" => "column_1700000000002" })

    migrate(:up)

    assert_equal({ "provider" => "hibob", "sync_enabled" => true, "level_field_id" => "work.customColumns.column_1700000000002" },
                 config_of(bare))
  end

  should "leave a path, a blank and a missing level field as they are" do
    path = stored({ "level_field_id" => "work.customColumns.column_1" })
    blank = stored({ "level_field_id" => "" })
    missing = stored({ "provider" => "hibob" })
    slashed = stored({ "level_field_id" => "/work/title" })

    migrate(:up)

    assert_equal({ "level_field_id" => "/work/title" }, config_of(slashed))

    assert_equal({ "level_field_id" => "work.customColumns.column_1" }, config_of(path))
    assert_equal({ "level_field_id" => "" }, config_of(blank))
    assert_equal({ "provider" => "hibob" }, config_of(missing))
  end

  should "reverse to the bare custom-column id" do
    bare = stored({ "level_field_id" => "column_1700000000002" })

    migrate(:up)
    migrate(:down)

    assert_equal({ "level_field_id" => "column_1700000000002" }, config_of(bare))
  end

  should "be read the same by the sync before and after" do
    tenant = stored({ "provider" => "hibob", "level_field_id" => "column_1700000000002" })
    before = Hris::Hibob::Client.field_path(tenant.reload.hris_config.level_field_id)

    migrate(:up)

    assert_equal before, Hris::Hibob::Client.field_path(tenant.reload.hris_config.level_field_id)
  end
end
