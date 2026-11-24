# frozen_string_literal: true

# Makes a person's account a member or an admin of the tenant ([#540](https://github.com/espaliahq/espalia/issues/540)).
# The organisation always keeps an admin, so demoting the last one is refused.
#
# Approval is :in_app, as it changes someone's permissions.
class Operations::Tenants::SetAccountRole < Operations::Base
  description "Set the role of a person's account in the active tenant: member, or admin. An admin manages " \
              "the tenant's people, settings and permissions. Refused unless the caller is a tenant admin, " \
              "and refused when it would leave the tenant with no admin. Returns the person and their role."
  category :write
  approval :in_app

  parameter :person_id, String, required: true, allow_blank: false
  parameter :role, String, required: true, allow_blank: false

  def policy_check
    authorize TenantUser, :update?
  end

  # @return [Hash] `{ person_id, role }`
  # @raise [ParameterError] for a person with no account, an unknown role, or demoting the last admin
  def perform
    role = params[:role].to_s
    raise ParameterError, "role: must be one of #{AccountGrants::Aggregate::ROLES.join(', ')}" unless AccountGrants::Aggregate::ROLES.include?(role)

    account = TenantUser.find_by(person_id: params[:person_id].to_s.downcase) or
      raise ParameterError, "person_id: that person has no account in this organisation"

    AccountGrants::CommandHandler.new.set_role(account, role, set_by_id: context.person&.id)
    { person_id: account.person_id, role: account.reload.role }
  rescue AccountGrants::Aggregate::LastAdmin
    raise ParameterError, "role: that is the last tenant administrator, so promote another member first"
  end
end
