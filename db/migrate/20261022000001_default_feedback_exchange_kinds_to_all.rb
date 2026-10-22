# frozen_string_literal: true

# The exchange's type lists gained "all" (every type, including ones added
# later), and it became the default for both. Stored configs keep their meaning:
#
# - an empty `import_kinds` meant "import everything", and now means "import
#   nothing", so it becomes ["all"];
# - an `export_kinds` equal to the old code default was never an admin's choice,
#   so it follows the new default to ["all"]. Any other stored list is kept.
#
# A config that never stored a list reads the new default already. The row
# class is local so a later change to Tenant cannot break this migration.
class DefaultFeedbackExchangeKindsToAll < ActiveRecord::Migration[8.1]
  class TenantRow < ActiveRecord::Base
    self.table_name = "tenants"
  end

  ALL = %w[all].freeze
  OLD_EXPORT_DEFAULT = %w[peer_feedback manager_feedback observation impact].freeze

  def up
    changed = rewrite_configs do |config|
      config["import_kinds"] = ALL if config["import_kinds"] == []
      config["export_kinds"] = ALL if old_export_default?(config["export_kinds"])
    end
    say "#{changed} feedback exchange #{'config'.pluralize(changed)} changed"
  end

  def down
    changed = rewrite_configs do |config|
      config["import_kinds"] = [] if config["import_kinds"] == ALL
      config["export_kinds"] = OLD_EXPORT_DEFAULT if config["export_kinds"] == ALL
    end
    say "#{changed} feedback exchange #{'config'.pluralize(changed)} changed"
  end

  private

  def old_export_default?(kinds)
    kinds.is_a?(Array) && kinds.sort == OLD_EXPORT_DEFAULT.sort
  end

  # @return [Integer] how many configs the block changed
  def rewrite_configs
    TenantRow.where("feedback_exchange_config ?| array['import_kinds', 'export_kinds']").find_each.count do |row|
      config = row.feedback_exchange_config.deep_dup
      yield config
      next false if config == row.feedback_exchange_config

      row.update_columns(feedback_exchange_config: config)
    end
  end
end
