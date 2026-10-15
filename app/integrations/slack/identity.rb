# frozen_string_literal: true

# Who a Slack user is in GrowthOS: the tenant whose workspace the request
# came from, and the membership behind the Slack user — by the id cached on
# `TenantUser.slack_user_id`, else by the email Slack holds for them. The
# cache is filled on the way through, the same column the outbound DM
# delivery fills, so the two directions agree.
#
# Three outcomes, and the caller decides what to say for each:
#
# - {#member?} — a TenantUser with a Person: act as them.
# - {#person_only?} — a Person with that email (HRIS-imported) but no account
#   yet: they have to sign in once; see Evidence::DraftsController.
# - neither — no GrowthOS identity for the Slack email, or the workspace is
#   not connected.
class Slack::Identity
  # @return [Tenant, nil]
  attr_reader :tenant
  # @return [TenantUser, nil]
  attr_reader :tenant_user
  # @return [Person, nil]
  attr_reader :person
  # @return [String, nil] the email Slack holds for the user
  attr_reader :email

  # @param team_id [String] the workspace the request came from
  # @param slack_user_id [String]
  # @param client [Slack::Client, nil] injectable for tests
  # @return [Slack::Identity]
  def self.resolve(team_id:, slack_user_id:, client: nil)
    tenant = Tenant.find_by(slack_team_id: team_id)
    return new(tenant: nil) if tenant.nil? || !tenant.slack_connected?

    ActsAsTenant.with_tenant(tenant) do
      membership = TenantUser.find_by(slack_user_id: slack_user_id)
      return new(tenant: tenant, tenant_user: membership, person: membership.person || membership.ensure_person!) if membership

      email = (client || Slack::Client.new(bot_token: tenant.slack_bot_token)).user_email(slack_user_id)
      return new(tenant: tenant) if email.blank?

      membership = membership_for(email)
      if membership
        membership.update_column(:slack_user_id, slack_user_id)
        new(tenant: tenant, tenant_user: membership, person: membership.person || membership.ensure_person!, email: email)
      else
        new(tenant: tenant, person: Person.where("LOWER(email) = ?", email.downcase).first, email: email)
      end
    end
  end

  def self.membership_for(email)
    user = User.find_by("LOWER(email) = ?", email.downcase)
    user && TenantUser.find_by(user_id: user.id)
  end
  private_class_method :membership_for

  def initialize(tenant:, tenant_user: nil, person: nil, email: nil)
    @tenant = tenant
    @tenant_user = tenant_user
    @person = person
    @email = email
  end

  # @return [Boolean] the workspace maps to a connected tenant
  def connected? = tenant.present?

  # @return [Boolean] a signed-up member who can act now
  def member? = tenant_user.present? && person.present?

  # @return [Boolean] known to HRIS but never signed in
  def person_only? = tenant_user.nil? && person.present?

  # @return [AuthorizationContext] for Operations, built like the MCP server's
  def authorization_context
    AuthorizationContext.new(user: tenant_user.user, tenant_user: tenant_user, person: person)
  end
end
