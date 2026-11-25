# frozen_string_literal: true

# What the planner operations share: finding a person's accounts in the
# tenant, and the list as it reads after a change.
#
# The grant is recorded in the TenantAccountGrants stream and read from
# tenant_users.team_planner (decision 7), in the Org Graph editor
# tools' shape.
module Operations::TeamPlanning::PlannerSupport
  include Operations::GrantHoldersPayload
  include Operations::PersonAccounts

  private

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_team_planners?, policy_class: TenantPolicy
  end

  def grant_handler
    AccountGrants::CommandHandler.new
  end

  # Admins may always create a plan, so they are listed apart from the planners an admin chose.
  def planners_payload = grant_holders_payload(:team_planner, :planners)
end
