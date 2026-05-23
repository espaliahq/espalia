# frozen_string_literal: true

# Returns the caller's identity as resolved by the MCP server: the User
# email, the active Tenant, and (if linked) the Person record.
#
# Read-only, no policy gate beyond "must be signed in" — which the MCP
# server already enforces via Doorkeeper. Exposed as the first concrete
# Operation primarily to exercise the end-to-end registry → tool →
# AuthorizationContext path before any business-domain Operations land.
class Operations::System::Whoami < Operations::Base
  description "Identify the user, tenant, and person the MCP token resolves to."
  category :read
  approval :none

  def policy_check
    # No record-level policy — being signed in is sufficient.
    raise Pundit::NotAuthorizedError, "not signed in" if context.user.nil?
  end

  def perform
    {
      user: {
        id: context.user.id,
        email: context.user.email,
        global_admin: context.user.global_admin?
      },
      tenant: tenant_payload,
      person: person_payload
    }
  end

  private

  def tenant_payload
    return nil unless context.tenant_user

    tenant = context.tenant_user.tenant
    {
      id: tenant.id,
      name: tenant.name,
      role: context.tenant_user.role
    }
  end

  def person_payload
    return nil unless context.person

    { id: context.person.id, name: context.person.name, email: context.person.email }
  end
end
