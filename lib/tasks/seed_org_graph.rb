# frozen_string_literal: true

# How the dev seeds reach the Org Graph. Once a tenant is cut over, its
# people's titles, managers and statuses come from their streams, so a seed
# changes them with commands, never on the row.
module SeedOrgGraph
  module_function

  # Cuts the tenant over, recording each person from their row. Does
  # nothing once the tenant is cut over.
  #
  # @param tenant [Tenant]
  # @raise [RuntimeError] when the cut-over refuses
  def cut_over!(tenant)
    return if tenant.org_graph_people_projected?

    report = OrgGraph::PeopleCutover.new(tenant).run(apply: true)
    return if report.applied

    raise "The Org Graph cut-over refused: #{report.failed.size} people failed to record, " \
          "and these columns differ: #{report.differences.keys.join(', ').presence || 'none'}"
  end

  # Runs Org Graph commands as the system, as the cut-over records people.
  #
  # @yieldparam handler [OrgGraph::CommandHandler]
  def as_system
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid_v7) do
      AuditMetadata.wrap_event_store { yield handler }
    end
  end
end
