# frozen_string_literal: true

class CreateTenantSettingChanges < ActiveRecord::Migration[8.1]
  # ComparisonConfig's DEFAULT_ and LOWEST_MIN_GROUP_SIZE when this ran; a migration doesn't read app constants.
  DEFAULT_MIN_GROUP_SIZE = 5
  LOWEST_MIN_GROUP_SIZE = 4

  def up
    create_table :tenant_setting_changes, id: :uuid, default: nil do |t|
      t.uuid :tenant_id, null: false
      t.string :setting, null: false
      t.string :value, null: false
      t.datetime :changed_at, null: false
    end
    add_index :tenant_setting_changes, %i[tenant_id setting changed_at]
    add_foreign_key :tenant_setting_changes, :tenants
    add_check_constraint :tenant_setting_changes, "setting IN ('time_zone', 'min_group_size')",
                         name: "tenant_setting_changes_setting"
    add_check_constraint :tenant_setting_changes, "setting <> 'min_group_size' OR value ~ '^[0-9]+$'",
                         name: "tenant_setting_changes_min_group_size_whole"

    # Each tenant's values today, dated from its creation: what we know was in force.
    # Postgres 16 has no uuidv7(), so the ids come from Ruby.
    tenants = select_rows(<<~SQL.squish)
      SELECT id, time_zone, comparison_config ? 'min_group_size', comparison_config ->> 'min_group_size', created_at
      FROM tenants ORDER BY created_at, id
    SQL
    return if tenants.empty?

    rows = tenants.flat_map do |id, zone, stored, size, created_at|
      { "time_zone" => zone, "min_group_size" => size_read(stored, size) }.map do |setting, value|
        "(#{[ SecureRandom.uuid_v7, id, setting, value, created_at ].map { connection.quote(it) }.join(', ')})"
      end
    end
    execute "INSERT INTO tenant_setting_changes (id, tenant_id, setting, value, changed_at) VALUES #{rows.join(', ')}"
  end

  # The floor the app applies to what is stored: the default when no size is
  # stored, else the size cast as the integer attribute casts it, never below
  # the least an admin may set.
  def size_read(stored, size)
    return DEFAULT_MIN_GROUP_SIZE.to_s unless ActiveModel::Type::Boolean.new.cast(stored)

    [ ActiveModel::Type::Integer.new.cast(size).to_i, LOWEST_MIN_GROUP_SIZE ].max.to_s
  end

  def down
    drop_table :tenant_setting_changes
  end
end
