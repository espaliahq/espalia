# frozen_string_literal: true

# The settings screen's read of where the Org Graph's facts come from (#126):
# each kind of person fact and each structure level with its provider and
# field, and how many facts Espalia holds have gone stale. Counts only, never
# a person.
class Operations::OrgGraph::Sources < Operations::Base
  description "Read where the Org Graph's data comes from: the connected HRIS, each kind of person fact " \
              "with its provider and the fields an HRIS reads it from, each structure level (top first) " \
              "with its provider, field, how many live units it holds and how many retired units it held " \
              "(by distinct name, the first three of each named), the type ids it can sit under (parent_ids), " \
              "whether it can sit at the top and whether the caller can remove it today (as remove_level would accept it), the same for each unit that has a " \
              "structure of its own (structures, by unit_id and name), and the staleness threshold with how " \
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

  # @param levels [Array<OrgTaxonomyLevel>] one structure's, top first
  # @param structure_unit_id [String, nil] its declaring unit; nil for the top structure
  def levels_payload(levels, structure_unit_id)
    live = live_units_by_level
    retired = retired_units_by_level
    rules = OrgTaxonomyLevel.rules_by_id(levels)
    levels.map do |level|
      live_count, live_names = live.fetch(level.id, [ 0, [] ])
      retired_count, retired_names = retired.fetch(level.id, [ 0, [] ])
      { id: level.id, name: level.name, provider: level.provider, field: level.provider_field,
        live_units: live_count, live_unit_names: live_names, retired_units: retired_count,
        retired_unit_names: retired_names, removable: removable?(level, structure_unit_id),
        **rules[level.id] }
    end
  end

  def live_units_by_level = @live_units_by_level ||= names_by_level(OrgUnit.live)

  def retired_units_by_level = @retired_units_by_level ||= names_by_level(OrgUnit.where.not(retired_on: nil))

  # The panel offers Remove exactly when RemoveLevel would take it today: the
  # aggregate's own checks, then the live plans it can't see. Loading the
  # structure replays its whole stream (~0.6s at 3,000 events), so only a
  # caller who may remove the type pays for it.
  def removable?(level, structure_unit_id)
    return false unless level.provider == ::OrgGraph::StructureAggregate::ESPALIA
    return false unless may_remove_from?(structure_unit_id) && live_plans_by_level

    live_plans_by_level.fetch(level.id, 0).zero? && structure.removal_refusal(level.id, structure_unit_id:).nil?
  end

  def may_remove_from?(structure_unit_id)
    @may_remove_from ||= Hash.new do |allowed, unit_id|
      policy = Pundit.policy!(context, :org_graph)
      allowed[unit_id] = unit_id ? policy.edit_structure_of?(OrgUnit.find_by(id: unit_id)) : policy.edit_taxonomy?
    end
    @may_remove_from[structure_unit_id]
  end

  def structure = @structure ||= ::OrgGraph::Repository.new.load_structure

  # Nil mid-rebuild, when no type is offered for removal.
  def live_plans_by_level
    return @live_plans_by_level if defined?(@live_plans_by_level)

    @live_plans_by_level = ProjectionVersion.unless_rebuilding(TeamPlanning::Projections::Overrides::PROJECTION_NAME,
                                                               ::OrgGraph::Projections::Structure::PROJECTION_NAME) do
      TeamPlanningOverride.live_plans_by_level
    end
  rescue ProjectionVersion::Rebuilding
    @live_plans_by_level = nil
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
