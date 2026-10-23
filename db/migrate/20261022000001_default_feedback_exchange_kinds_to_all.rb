# frozen_string_literal: true

# The exchange's type lists gained "all" (every type, including ones added
# later), and it became the default for both. An empty `import_kinds` (or null,
# or only blanks, which the importer read the same way) meant "import
# everything" and now means "import nothing", so it becomes ["all"].
#
# A stored `export_kinds` is kept as it is, even when it equals the old code
# default: an admin may have chosen exactly those four types, and widening a
# choice would send types nobody agreed to. A config that never stored a list
# reads the new default already. The row class is local so a later change to
# Tenant cannot break this migration.
class DefaultFeedbackExchangeKindsToAll < ActiveRecord::Migration[8.1]
  class TenantRow < ActiveRecord::Base
    self.table_name = "tenants"
  end

  ALL = %w[all].freeze

  def up
    changed = rewrite_configs do |config|
      config["import_kinds"] = ALL if config.key?("import_kinds") && blank_list?(config["import_kinds"])
    end
    say "#{changed} feedback exchange #{'config'.pluralize(changed)} changed"
  end

  def down
    changed = rewrite_configs do |config|
      config["import_kinds"] = [] if config["import_kinds"] == ALL
    end
    say "#{changed} feedback exchange #{'config'.pluralize(changed)} changed"
  end

  private

  def blank_list?(kinds)
    kinds.nil? || (kinds.is_a?(Array) && kinds.all?(&:blank?))
  end

  # Locks and rereads each row first, so a sync job saving its cursor meanwhile
  # is not overwritten.
  #
  # @return [Integer] how many configs the block changed
  def rewrite_configs
    TenantRow.where("feedback_exchange_config ? 'import_kinds'").find_each.count do |row|
      row.with_lock do
        config = row.feedback_exchange_config.deep_dup
        yield config
        next false if config == row.feedback_exchange_config

        row.update_columns(feedback_exchange_config: config)
      end
    end
  end
end
