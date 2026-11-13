# frozen_string_literal: true

# Cuts one tenant's `people.job_title`, `manager_id` and `status` over to the
# Org Graph person streams (story 1.4), or back. Prints counts and person ids,
# never names or emails. See docs/runbooks/org-graph-first-sync.md.
#
# Usage:
#   bin/rails "org_graph:people:cut_over[<tenant id>]"                   # dry run
#   APPLY=1 bin/rails "org_graph:people:cut_over[<tenant id>]"
#   APPLY=1 ACCEPT_STREAM=1 bin/rails "org_graph:people:cut_over[<tenant id>]"
#   bin/rails "org_graph:people:revert[<tenant id>]"
namespace :org_graph do
  namespace :people do
    desc "Cut a tenant's people columns over to the Org Graph (dry run unless APPLY=1)"
    task :cut_over, [ :tenant_id ] => :environment do |_, args|
      tenant = Tenant.find(args.fetch(:tenant_id) { abort "Usage: org_graph:people:cut_over[<tenant id>]" })
      report = OrgGraph::PeopleCutover.new(tenant).run(apply: ENV["APPLY"] == "1", accept_stream: ENV["ACCEPT_STREAM"] == "1")

      puts "recorded from their row: #{report.recorded.size}"
      report.recorded.each { |id| puts "  #{id}" }
      puts "could not be recorded: #{report.failed.size}"
      report.failed.each { |id, reason| puts "  #{id}: #{reason}" }
      report.differences.each do |column, ids|
        puts "#{column} differs from the stream: #{ids.size}"
        ids.each { |id| puts "  #{id}" }
      end
      puts "differences: none" if report.differences.empty?
      puts report.applied ? "cut over: yes" : "cut over: no, nothing was kept"
    end

    desc "Hand a tenant's people columns back to the HRIS sync"
    task :revert, [ :tenant_id ] => :environment do |_, args|
      tenant = Tenant.find(args.fetch(:tenant_id) { abort "Usage: org_graph:people:revert[<tenant id>]" })
      OrgGraph::PeopleCutover.new(tenant).revert!
      puts "reverted: the next sync writes the columns"
    end
  end
end
