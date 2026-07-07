# frozen_string_literal: true

# Base policy for Pundit authorization.
#
# Receives an {AuthorizationContext} (not a raw User) as the first argument,
# providing access to the full identity chain: User → TenantUser → Person.
#
# All actions default to deny. Subclasses override specific actions.
#
class ApplicationPolicy
  attr_reader :context, :record

  # @param context [AuthorizationContext] the identity chain for the current request
  # @param record [Object] the resource being authorized
  def initialize(context, record)
    @context = context
    @record = record
  end

  delegate :user, :tenant_user, :person, to: :context

  # @return [Boolean] whether the user is a tenant admin or global admin
  delegate :tenant_admin?, to: :context

  # @return [Boolean] whether the user has any membership in the current tenant
  def tenant_member?
    tenant_user.present?
  end

  def index?   = false
  def show?    = false
  def create?  = false
  def update?  = false
  def destroy? = false
end
