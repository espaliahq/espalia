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

  # Whether the identity carries admin authority in the active tenant — a
  # global (platform) admin or a tenant-role admin. Single source for the
  # predicate shared by policies ({ApplicationPolicy#tenant_admin?}) and bulk
  # query objects ({Assessments::ViewableAssessments}).
  #
  # @return [Boolean]
  def tenant_admin?
    user&.global_admin? || tenant_user&.admin? || false
  end

  # Whether the membership carries the Org Graph editor grant, which lets the
  # people team edit any unit and membership without being an admin.
  #
  # @return [Boolean]
  def org_graph_editor?
    tenant_user&.org_graph_editor? || false
  end

  # The same identity as the database holds it now. A record since deleted
  # comes back nil, and so does a person the account no longer links to, so
  # neither grants anything.
  #
  # @return [AuthorizationContext]
  def reread
    ActsAsTenant.without_tenant do
      fresh_tenant_user = tenant_user && TenantUser.find_by(id: tenant_user.id)
      still_linked = person && (tenant_user.nil? || fresh_tenant_user&.person_id == person.id)
      self.class.new(user: user && User.find_by(id: user.id),
                     tenant_user: fresh_tenant_user,
                     person: still_linked ? Person.find_by(id: person.id) : nil)
    end
  end

  # Whether the membership carries the planner grant, which lets someone
  # create Team Planning plans without being an admin.
  #
  # @return [Boolean]
  def team_planner?
    tenant_user&.team_planner? || false
  end
end
