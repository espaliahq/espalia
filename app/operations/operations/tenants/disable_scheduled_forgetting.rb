# frozen_string_literal: true

# Turns off the daily forgetting job for the active tenant. Nothing already
# forgotten comes back.
class Operations::Tenants::DisableScheduledForgetting < Operations::Base
  description "Turn off scheduled forgetting for the active tenant. Anyone already forgotten stays forgotten."
  category :write
  approval :in_app

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :forget_person?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id and scheduled_forgetting
  def perform
    tenant = ActsAsTenant.current_tenant
    TenantSettings::CommandHandler.new(tenant).disable_scheduled_forgetting(disabled_by: context.tenant_user)
    Rails.logger.info("[OrgGraph::Forgetting] disabled tenant=#{tenant.id} requested_by=#{context.tenant_user&.id}")
    { tenant_id: tenant.id, scheduled_forgetting: false }
  end
end
