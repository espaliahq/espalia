# frozen_string_literal: true

# The settings screen's read of where the Org Graph's facts come from (#126):
# each kind of person fact and each structure level with its provider and
# field, and how many facts Espalia holds have gone stale. Counts only, never
# a person.
class Operations::OrgGraph::Sources < Operations::Base
  description "Read where the Org Graph's data comes from: the connected HRIS, each kind of person fact " \
              "with its provider and the fields an HRIS reads it from, each structure level (top first) " \
              "with its provider, field, how many live units it holds and how many retired units it held " \
              "(by distinct name, the first three of each named) and whether it can be removed, and the staleness threshold with how " \
              "many facts Espalia holds are stale, by fact. Admins and Org Graph editors only."
  category :read
  approval :none

  NAMES_SHOWN = 3

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
    live = names_by_level(OrgUnit.live)
    retired = names_by_level(OrgUnit.where.not(retired_on: nil))
    levels = OrgTaxonomyLevel.top_first.to_a
    levels.map do |level|
      live_count, live_names = live.fetch(level.id, [ 0, [] ])
      retired_count, retired_names = retired.fetch(level.id, [ 0, [] ])
      { id: level.id, name: level.name, provider: level.provider, field: level.provider_field,
        live_units: live_count, live_unit_names: live_names, retired_units: retired_count,
        retired_unit_names: retired_names, removable: removable?(level, live_count + retired_count, levels.size) }
    end
  end

  # The aggregate refuses the rest: a level that ever held a unit stays to
  # explain the unit's history, and a taxonomy keeps at least one level.
  def removable?(level, units_ever, level_count)
    level.provider == ::OrgGraph::StructureAggregate::ESPALIA && units_ever.zero? && level_count > 1
  end

  # Live units' names are unique, so the count is the number of live units;
  # retired ones can share a name and are counted by name.
  #
  # @param units [ActiveRecord::Relation<OrgUnit>]
  # @return [Hash{String => Array(Integer, Array<String>)}] per level, how many
  #   distinct names its units have and the first few, alphabetically
  def names_by_level(units)
    units.group(:level_id)
         .pluck(:level_id, Arel.sql("count(DISTINCT name)"),
                Arel.sql("(array_agg(DISTINCT name ORDER BY name))[1:#{NAMES_SHOWN}]"))
         .to_h { |level_id, count, names| [ level_id, [ count, names ] ] }
  end
end
