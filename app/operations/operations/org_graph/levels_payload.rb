# frozen_string_literal: true

# One structure's unit types as the settings screen and the structure page
# read them: each with its provider, its units, where it can sit, and whether
# the caller can remove it today.
module Operations::OrgGraph::LevelsPayload
  NAMES_SHOWN = 3

  private

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
