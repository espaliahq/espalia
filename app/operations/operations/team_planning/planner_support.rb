# frozen_string_literal: true

# What the planner operations share: finding a person's account in the
# tenant, and the list as it reads after a change.
#
# The grant is recorded in the AccountGrants stream and read from
# tenant_users.team_planner (decision 7), in the Org Graph editor
# tools' shape.
module Operations::TeamPlanning::PlannerSupport
  include Operations::GrantHoldersPayload

  private

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_team_planners?, policy_class: TenantPolicy
  end

  def grant_handler
    AccountGrants::CommandHandler.new
  end

  def account!
    TenantUser.find_by(person_id: params[:person_id].to_s.downcase) or
      raise Operations::Base::ParameterError, "person_id: that person has no account in this organisation"
  end

  # Admins may always create a plan, so they are listed apart from the planners an admin chose.
  def planners_payload = grant_holders_payload(:team_planner, :planners)
end
