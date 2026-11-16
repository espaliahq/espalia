# frozen_string_literal: true

# Pay bands become an ordered list of entries ([#368](https://github.com/espaliahq/espalia/issues/368)). Each band matches on
# whichever of role family, role, level number and location it sets, and of
# the bands that match a seat, the last in the list has the last word.
#
# Existing bands become role plus level number plus their location. Every
# any-location band sits above every country band, so a seat prices as it did.
# level_id stays as legacy matching: a band made from a level keeps it, so a
# seat at a level that has left the framework still finds its band.
class AddMatcherToPayBands < ActiveRecord::Migration[8.1]
  def up
    add_column :pay_bands, :role_family_id, :uuid
    add_column :pay_bands, :role_id, :uuid
    add_column :pay_bands, :level_ordinal, :integer
    add_column :pay_bands, :position, :integer
    change_column_null :pay_bands, :level_id, true

    execute <<~SQL.squish
      UPDATE pay_bands SET role_id = framework_levels.role_id, level_ordinal = framework_levels.ordinal
      FROM framework_levels
      WHERE framework_levels.tenant_id = pay_bands.tenant_id AND framework_levels.level_id = pay_bands.level_id
    SQL
    execute <<~SQL.squish
      UPDATE pay_bands SET position = ranked.position
      FROM (SELECT id, row_number() OVER (PARTITION BY tenant_id ORDER BY location_key <> '', created_at, id) AS position
            FROM pay_bands) ranked
      WHERE ranked.id = pay_bands.id
    SQL
    change_column_null :pay_bands, :position, false

    remove_index :pay_bands, name: "index_pay_bands_on_tenant_id_and_level_id_and_location_key"
    add_index :pay_bands, %i[tenant_id role_family_id role_id level_ordinal level_id location_key], unique: true,
              nulls_not_distinct: true, name: "index_pay_bands_one_per_matcher"
    add_index :pay_bands, %i[tenant_id position]
    add_check_constraint :pay_bands, "level_ordinal > 0", name: "pay_bands_level_number_positive"
    add_check_constraint :pay_bands, "role_id IS NULL OR role_family_id IS NULL", name: "pay_bands_role_or_family"
  end

  def down
    execute "DELETE FROM pay_bands WHERE level_id IS NULL"
    remove_check_constraint :pay_bands, name: "pay_bands_role_or_family"
    remove_check_constraint :pay_bands, name: "pay_bands_level_number_positive"
    remove_index :pay_bands, name: "index_pay_bands_one_per_matcher"
    remove_index :pay_bands, %i[tenant_id position]
    execute <<~SQL.squish
      DELETE FROM pay_bands WHERE id IN (
        SELECT id FROM (SELECT id, row_number() OVER (PARTITION BY tenant_id, level_id, location_key ORDER BY position DESC) AS n
                        FROM pay_bands) ranked WHERE n > 1)
    SQL
    add_index :pay_bands, %i[tenant_id level_id location_key], unique: true
    change_column_null :pay_bands, :level_id, false
    remove_column :pay_bands, :position
    remove_column :pay_bands, :level_ordinal
    remove_column :pay_bands, :role_id
    remove_column :pay_bands, :role_family_id
  end
end
