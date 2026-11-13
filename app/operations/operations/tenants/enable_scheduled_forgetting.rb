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
    count = tenant.with_lock { confirm_and_enable(tenant) }
    Rails.logger.info("[OrgGraph::Forgetting] enabled tenant=#{tenant.id} requested_by=#{context.tenant_user&.id} " \
                      "reason=retention count=#{count}")
    { tenant_id: tenant.id, scheduled_forgetting: true, confirmed_count: count }
  end

  private

  # Under the tenant's row lock, so the retention period the count was taken
  # with is the one the schedule starts under.
  def confirm_and_enable(tenant)
    raise ParameterError, "retention is set to never, so there is nothing to schedule" unless
      tenant.org_graph_config.retention_years

    count = Operations::Tenants::ForgettingDryRun.report(tenant).count
    raise ParameterError, "#{count} leavers are due now, not #{params[:confirm_count]}: run the dry run again" unless
      count == params[:confirm_count]

    config = tenant.org_graph_config.dup
    config.scheduled_forgetting = true
    config.scheduled_forgetting_enabled_at = Time.current
    config.scheduled_forgetting_enabled_by_id = context.tenant_user&.id
    tenant.update!(org_graph_config: config)
    count
  end
end
