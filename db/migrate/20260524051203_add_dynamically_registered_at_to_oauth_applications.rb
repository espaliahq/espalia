# frozen_string_literal: true

# Distinguishes OAuth applications created via Dynamic Client Registration
# (POST /oauth/register, every fresh MCP CLI install) from those created
# through the admin UI by a human operator. Only DCR rows are auto-pruned
# by Mcp::PruneStaleClientsJob; admin-registered apps stay around until
# the operator removes them.
#
# Nullable on purpose: existing manually-registered apps stay nil and are
# never touched by the pruner.
class AddDynamicallyRegisteredAtToOauthApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_applications, :dynamically_registered_at, :datetime
    add_index  :oauth_applications, :dynamically_registered_at,
      where: "dynamically_registered_at IS NOT NULL",
      name: "idx_oauth_applications_dcr_registered"
  end
end
