# frozen_string_literal: true

# The HRIS level field was a pasted HiBob custom-column id (`column_…`). The
# field picker (#67) stores the catalogue id instead, the field's full path
# (`work.customColumns.column_…`), so a bare id gains the prefix. A path or a
# blank is left as it is. The HiBob client and mapper read both forms, so the
# sync is right whichever lands first. The row class is local so a later change
# to Tenant cannot break this migration.
class StoreHrisLevelFieldAsCatalogueId < ActiveRecord::Migration[8.1]
  class TenantRow < ActiveRecord::Base
    self.table_name = "tenants"
  end

  PREFIX = "work.customColumns."
  BARE_CUSTOM_COLUMN = /\Acolumn_[^.\/]+\z/

  def up
    changed = rewrite_level_fields { |id| id.match?(BARE_CUSTOM_COLUMN) ? "#{PREFIX}#{id}" : id }
    say "#{changed} HRIS level #{'field'.pluralize(changed)} moved to the catalogue id"
  end

  # A built-in field chosen with the picker since (`work.title`) has no bare
  # form, and the old client would not find it; it is left for an admin.
  def down
    changed = rewrite_level_fields { |id| id.delete_prefix(PREFIX) }
    say "#{changed} HRIS level #{'field'.pluralize(changed)} moved back to the bare column id"
  end

  private

  # Locks and rereads each row first, so a sync stamping `last_synced_at`
  # meanwhile is not overwritten.
  #
  # @return [Integer] how many configs the block changed
  def rewrite_level_fields
    TenantRow.where("coalesce(hris_config ->> 'level_field_id', '') <> ''").find_each.count do |row|
      row.with_lock do
        config = row.hris_config.deep_dup
        config["level_field_id"] = yield(config["level_field_id"].to_s.strip)
        next false if config == row.hris_config

        row.update_columns(hris_config: config)
      end
    end
  end
end
