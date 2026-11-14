# frozen_string_literal: true

# The planner grant (Team Planning decision 7): a tenant admin lets someone
# create plans without making them an admin. It opens no one else's plan.
class AddTeamPlannerToTenantUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_users, :team_planner, :boolean, default: false, null: false
  end
end
