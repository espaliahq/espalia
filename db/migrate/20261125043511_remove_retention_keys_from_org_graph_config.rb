# frozen_string_literal: true

# The TenantSettings stream holds retention and scheduled forgetting now.
# There is no down: the stream is the truth, and a release that reads the
# keys must not be deployed again (see docs/runbooks/org-graph-forgetting.md).
class RemoveRetentionKeysFromOrgGraphConfig < ActiveRecord::Migration[8.1]
  KEYS = %w[retention_years scheduled_forgetting scheduled_forgetting_enabled_at scheduled_forgetting_enabled_by_id].freeze

  def up
    execute <<~SQL
      UPDATE tenants
      SET org_graph_config = org_graph_config - ARRAY[#{KEYS.map { connection.quote(it) }.join(", ")}]::text[]
      WHERE org_graph_config ?| ARRAY[#{KEYS.map { connection.quote(it) }.join(", ")}]
    SQL
  end

  def down; end
end
