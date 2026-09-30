# frozen_string_literal: true

# Authorization policy for the integration management screens.
#
# Used as a Pundit headless symbol policy:
#
#   authorize :integrations, :index?
#
# All actions require tenant admin (or global admin). Members and
# unauthenticated visitors are denied.
#
class IntegrationsPolicy < ApplicationPolicy
  # @return [Boolean]
  def index?  = tenant_admin?

  # @return [Boolean]
  def show?   = tenant_admin?

  # @return [Boolean]
  def sync?   = tenant_admin?

  # Map or unmap an HRIS job title to a framework role (#436).
  # @return [Boolean]
  def update_role_mappings? = tenant_admin?

  # Connect / disconnect the tenant's Slack workspace.
  # @return [Boolean]
  def connect?    = tenant_admin?

  # @return [Boolean]
  def disconnect? = tenant_admin?
end
