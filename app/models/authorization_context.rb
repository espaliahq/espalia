# frozen_string_literal: true

# Value object carrying the full identity chain for Pundit authorization.
#
# Passed as `pundit_user` so policies can access the User, TenantUser,
# and Person without extra queries.
#
# @example
#   context = AuthorizationContext.new(user: current_user, tenant_user: tu, person: p)
#   FrameworkPolicy.new(context, @framework).show?
#
class AuthorizationContext
  attr_reader :user, :tenant_user, :person

  # @param user [User] the authenticated Devise user
  # @param tenant_user [TenantUser, nil] the user's membership in the active tenant
  # @param person [Person, nil] the domain Person entity linked to this membership
  def initialize(user:, tenant_user:, person:)
    @user = user
    @tenant_user = tenant_user
    @person = person
  end
end
