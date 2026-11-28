# frozen_string_literal: true

# The settings screen's read of where the Org Graph's facts come from (#126):
# each kind of person fact and each structure level with its provider and
# field, and how many facts Espalia holds have gone stale. Counts only, never
# a person.
class Operations::OrgGraph::Sources < Operations::Base
  include Operations::OrgGraph::LevelsPayload

  description "Read where the Org Graph's data comes from: the connected HRIS, each kind of person fact " \
              "with its provider and the fields an HRIS reads it from, each structure level (top first) " \
              "with its provider, field, how many live units it holds and how many retired units it held " \
              "(by distinct name, the first three of each named), the type ids it can sit under (parent_ids), " \
              "whether it can sit at the top and whether the caller can remove it today (as remove_level would accept it), the same for each unit that has a " \
              "structure of its own (structures, by unit_id and name), and the staleness threshold with how " \
              "many facts Espalia holds are stale, by fact. Admins and Org Graph editors only."
  category :read
  approval :none

  # @raise [Pundit::NotAuthorizedError] unless the caller may change the Org Graph's structure
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
      levels: levels_payload(OrgTaxonomyLevel.top_structure.to_a, nil),
      structures: structures_payload,
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

  def structures_payload
    declared = OrgTaxonomyLevel.where.not(structure_unit_id: nil).order(:position).group_by(&:structure_unit_id)
    names = OrgUnit.where(id: declared.keys).pluck(:id, :name).to_h
    declared.sort_by { |unit_id, _| names[unit_id].to_s }.map do |unit_id, levels|
      { unit_id:, name: names[unit_id], levels: levels_payload(levels, unit_id) }
    end
  end
end
