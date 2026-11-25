# frozen_string_literal: true

# Turns on the daily job that forgets the active tenant's leavers once their
# retention period ends. The caller confirms the count the dry run gave, so
# nobody turns it on without seeing how many it would forget at once.
class Operations::Tenants::EnableScheduledForgetting < Operations::Base
  description "Turn on scheduled forgetting for the active tenant. Pass confirm_count, the count " \
              "tenants_forgetting_dry_run gives now; the call is refused if it differs."
  category :write
  approval :in_app

  parameter :confirm_count, Integer, required: true

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :forget_person?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id, scheduled_forgetting and the count confirmed
  # @raise [ParameterError] without the forgetting key, or when the count has moved
  def perform
    tenant = ActsAsTenant.current_tenant
    count = TenantSettings::CommandHandler.new(tenant).enable_scheduled_forgetting(enabled_by: context.tenant_user) do
      confirm(tenant)
    end
    Rails.logger.info("[OrgGraph::Forgetting] enabled tenant=#{tenant.id} requested_by=#{context.tenant_user&.id} " \
                      "reason=retention count=#{count}")
    { tenant_id: tenant.id, scheduled_forgetting: true, confirmed_count: count }
  rescue TenantSettings::Aggregate::Refused => e
    raise ParameterError, e.message
  end

  private

  # Under the settings' lock and the tenant's row lock, so the retention
  # period the count was taken with is the one the schedule starts under.
  def confirm(tenant)
    count = Operations::Tenants::ForgettingDryRun.report(tenant).count
    raise TenantSettings::Aggregate::Refused, "#{count} leavers are due now, not #{params[:confirm_count]}: run the dry run again" unless
      count == params[:confirm_count]

    count
  end
end
