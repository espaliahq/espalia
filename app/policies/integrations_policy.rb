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

  # Save the HRIS connection settings and credentials.
  # @return [Boolean]
  def update_hris_connection? = tenant_admin?

  # Sever the HRIS connection (credentials gone, sync off).
  # @return [Boolean]
  def disconnect_hris? = tenant_admin?

  # Hand a structure level to an HRIS field, or back to Espalia.
  # @return [Boolean]
  def hand_over_hris_level? = tenant_admin?

  # Remove the AI model's API key (suggestions go off with it).
  # @return [Boolean]
  def remove_ai_key? = tenant_admin?

  # Sever the feedback exchange (secrets gone, exchange off).
  # @return [Boolean]
  def disconnect_feedback_exchange? = tenant_admin?

  # Save the AI model settings and key.
  # @return [Boolean]
  def update_ai_model? = tenant_admin?

  # Send the AI model one short request to check the key, address and model id.
  # @return [Boolean]
  def test_ai_model? = tenant_admin?

  # Save the feedback exchange settings and secrets.
  # @return [Boolean]
  def update_feedback_exchange? = tenant_admin?

  # Call the feedback exchange peer's /health to check the pair.
  # @return [Boolean]
  def test_feedback_exchange? = tenant_admin?

  # Connect / disconnect the tenant's Slack workspace.
  # @return [Boolean]
  def connect?    = tenant_admin?

  # @return [Boolean]
  def disconnect? = tenant_admin?
end
