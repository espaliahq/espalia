# frozen_string_literal: true

# What the planner operations share: finding a person's account in the
# tenant, and the list as it reads after a change.
module Operations::TeamPlanning::PlannerSupport
  private

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_team_planners?, policy_class: TenantPolicy
  end

  def account!
    TenantUser.find_by(person_id: params[:person_id].to_s.downcase) or
      raise Operations::Base::ParameterError, "person_id: that person has no account in this organisation"
  end

  # Admins may always create a plan, so they are listed apart from the
  # planners an admin chose.
  def planners_payload
    accounts = TenantUser.where(role: :admin).or(TenantUser.where(team_planner: true)).includes(:person, :user)
    admins, planners = accounts.partition(&:admin?)
    { planners: planners.map { account_payload(it) }.sort_by { it[:name].to_s }, admins: admins.map { account_payload(it) }.sort_by { it[:name].to_s } }
  end

  def account_payload(account)
    { person_id: account.person_id, name: account.person&.name || account.user&.email }
  end
end
