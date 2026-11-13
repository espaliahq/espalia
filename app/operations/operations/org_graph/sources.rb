# frozen_string_literal: true

# The settings screen's read of where the Org Graph's facts come from (#126):
# each kind of person fact and each structure level with its provider and
# field, and how many facts Espalia holds have gone stale. Counts only, never
# a person.
class Operations::OrgGraph::Sources < Operations::Base
  description "Read where the Org Graph's data comes from: the connected HRIS, each kind of person fact " \
              "with its provider and the fields an HRIS reads it from, each structure level (top first) " \
              "with its provider, field and number of live units, and the staleness threshold with how " \
              "many facts Espalia holds are stale, by fact. Admins and Org Graph editors only."
  category :read
  approval :none

  def policy_check
    authorize :org_graph, :edit_structure?
  end

  # @return [Hash] hris, facts, levels and freshness
  def perform
    tenant = ActsAsTenant.current_tenant
    stale = OrgFactAge.stale(tenant).reorder(nil).group(:fact).count
    {
      hris: hris_payload(tenant),
      facts: facts_payload,
      levels: levels_payload,
      freshness: { staleness_days: tenant.org_graph_config.staleness_days, stale: stale.values.sum, stale_by_fact: stale }
    }
  end

  private

  def hris_payload(tenant)
    config = tenant.hris_config
    { provider: config.provider.presence, label: (HrisConfig.provider_label(config.provider) if config.provider.present?),
      connected: config.connected?(tenant) }
  end

  def facts_payload
    rows = OrgFactProvider.all.index_by(&:fact)
    ::OrgGraph::StructureAggregate::FACTS.map do |fact|
      row = rows[fact]
      { fact:, provider: row&.provider || ::OrgGraph::StructureAggregate::ESPALIA, fields: row&.fields || {},
        mappable_parts: ::OrgGraph::StructureAggregate::MAPPABLE_FIELDS.fetch(fact, []), effective_on: row&.effective_on }
    end
  end

  def levels_payload
    live = OrgUnit.live.group(:level_id).count
    OrgTaxonomyLevel.top_first.map do |level|
      { id: level.id, name: level.name, provider: level.provider, field: level.provider_field, live_units: live.fetch(level.id, 0) }
    end
  end
end
