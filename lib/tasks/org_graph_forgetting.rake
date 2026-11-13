# frozen_string_literal: true

# Operator tasks for forgetting leavers. Output is counts and person ids only.
namespace :org_graph do
  namespace :forgetting do
    desc "Count the leavers a tenant would forget today, and list their ids. Erases nothing."
    task :dry_run, %i[tenant_id] => :environment do |_task, args|
      tenant = Tenant.find(args.fetch(:tenant_id))
      OrgGraph::Forgetting.key!
      report = OrgGraph::Forgetting.new(tenant).dry_run
      puts "[#{tenant.id}] #{report.count} due: #{report.person_ids.join(", ")}"
    end

    desc "Forget one leaver at a tenant admin's request. BEFORE_DUE=1 forgets a leaver whose period hasn't ended."
    task :forget, %i[tenant_id person_id requested_by_tenant_user_id] => :environment do |_task, args|
      tenant = Tenant.find(args.fetch(:tenant_id))
      ActsAsTenant.with_tenant(tenant) do
        admin = TenantUser.find(args.fetch(:requested_by_tenant_user_id))
        context = AuthorizationContext.new(user: admin.user, tenant_user: admin, person: admin.person)
        AuditMetadata.with(acting_via: :system, actor_id: admin.person_id) do
          forgot = OrgGraph::Forgetting.new(tenant).forget(args.fetch(:person_id), requested_by: context,
                                                                                   before_due: ENV["BEFORE_DUE"] == "1")
          puts "[#{tenant.id}] #{args[:person_id]} #{forgot ? "forgotten" : "was already forgotten"}"
        end
      end
    end
  end
end
