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

    failures = report.failed.first(3).map { |id, message| "#{id}: #{message}" }.join("; ").presence || "none"
    raise "The Org Graph cut-over refused. People who failed to record: #{failures}. " \
          "Columns that differ: #{report.differences.keys.join(', ').presence || 'none'}"
  end

  # Who may change the person's manager: their HRIS while it holds the
  # manager fact and carries their external id, and otherwise Espalia.
  #
  # @param person [Person]
  # @return [String]
  def manager_provider_for(person)
    holder = OrgGraph::Repository.new.fact_providers.fetch("manager", OrgGraph::StructureAggregate::ESPALIA)
    holder == person.hris_source && person.external_id.present? ? holder : OrgGraph::StructureAggregate::ESPALIA
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
