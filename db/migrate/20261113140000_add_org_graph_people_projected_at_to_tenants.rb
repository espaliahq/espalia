# frozen_string_literal: true

# When a tenant's `people` operational columns started coming from the Org
# Graph person streams. Nil while the HRIS sync still writes them directly.
class AddOrgGraphPeopleProjectedAtToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :org_graph_people_projected_at, :datetime
  end
end
