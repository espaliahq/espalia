# frozen_string_literal: true

# Daily (config/recurring.yml): forgets the leavers whose retention period
# has ended, in every tenant that turned scheduled forgetting on. Each
# person is one transaction, so a run that dies partway is finished by the
# next. The log holds counts and person ids only.
class OrgGraph::ForgetDueLeaversJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "org_graph_forget_due_leavers", duration: 6.hours

  # @return [void]
  # @raise [OrgGraph::Forgetting::KeyMissing] when any tenant is scheduled and the key is not set
  def perform
    tenants = TenantRetentionSetting.scheduled_tenants
    return unless tenants.exists?

    OrgGraph::Forgetting.key!
    AuditMetadata.with(acting_via: :system, correlation_id: job_id) do
      tenants.find_each { |tenant| forget_in(tenant) }
    end
  end

  private

  # One tenant's failure, such as an HRIS that doesn't answer, must not stop
  # the others; that tenant's leavers stay due for tomorrow.
  def forget_in(tenant)
    report = OrgGraph::Forgetting.new(tenant).forget_due(scheduled: true)
    Rails.logger.info("[OrgGraph::Forgetting] scheduled tenant=#{tenant.id} reason=retention " \
                      "count=#{report.count} held_back=#{report.held_back} person_ids=#{report.person_ids.join(',')}")
    report_held_back(tenant, report.held_back) if report.held_back.positive?
  rescue => e
    Rails.error.report(e, context: { tenant_id: tenant.id, job: self.class.name })
    Rails.logger.error("[OrgGraph::Forgetting] scheduled tenant=#{tenant.id} failed: #{e.class}")
  end

  # They stay due every day until someone else is made an admin, so someone
  # has to hear about it.
  def report_held_back(tenant, held_back)
    Rails.error.report(OrgGraph::Forgetting::LastAdmin.new, handled: true, severity: :warning,
                       context: { tenant_id: tenant.id, held_back:, job: self.class.name })
  end
end
