# frozen_string_literal: true

# Who scheduled forgetting would erase today: the leavers whose retention
# period has ended, less anyone the HRIS still shows as employed or starting.
# Ids only, so the answer never names anyone.
#
# Each call is logged with who asked and why, as ids, since knowing who is
# due is itself a step towards forgetting them.
class Operations::Tenants::ForgettingDryRun < Operations::Base
  REASONS = ::OrgGraph::PersonAggregate::FORGETTING_REASONS

  description "Count the leavers the active tenant would forget today, after checking the HRIS, " \
              "and list their person ids. Erases nothing. reason, why you ask, is recorded and doesn't change the answer."
  category :read

  parameter :reason, String, allowed: REASONS

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :forget_person?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id, retention_years, count and person_ids
  # @raise [ParameterError] when the forgetting key is not set
  def perform
    tenant = ActsAsTenant.current_tenant
    report = self.class.report(tenant)
    Rails.logger.info("[OrgGraph::Forgetting] dry_run tenant=#{tenant.id} requested_by=#{context.tenant_user&.id} " \
                      "reason=#{params[:reason] || 'retention'} count=#{report.count} person_ids=#{report.person_ids.join(',')}")
    { tenant_id: tenant.id, retention_years: tenant.org_graph_config.retention_years,
      count: report.count, person_ids: report.person_ids }
  end

  # @param tenant [Tenant]
  # @return [OrgGraph::Forgetting::Report]
  # @raise [ParameterError] when the forgetting key is not set
  def self.report(tenant)
    ::OrgGraph::Forgetting.key!
    ::OrgGraph::Forgetting.new(tenant).dry_run
  rescue ::OrgGraph::Forgetting::KeyMissing => e
    raise ParameterError, e.message
  end
end
