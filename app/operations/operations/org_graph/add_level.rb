# frozen_string_literal: true

# Adds a level Espalia holds at the bottom of the tenant's taxonomy.
class Operations::OrgGraph::AddLevel < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Add a level to the bottom of the Org Graph's taxonomy, from effective_on (today by default). " \
              "Espalia holds the new level. parent_ids lists the level_ids it can sit under (by default, every " \
              "level above it), and top whether it can sit at the top (by default, only when parent_ids is " \
              "empty, or when neither is given). org_graph_set_kind_parents changes these later. " \
              "Level names are unique, ignoring case, within a structure. structure_unit_id adds the type to that " \
              "unit's own structure instead of the top one. " \
              "Changing the organisation's structure needs a tenant admin or an Org Graph editor. A unit's own structure " \
              "can also be changed by an owner of that unit or a unit above it, or by anyone they report to."
  approval :in_app

  parameter :name, String, required: true, allow_blank: false
  parameter :parent_ids, Array,
            schema: { type: "array", items: { type: "string" }, description: "level_ids the new level can sit under" }
  parameter :top, :boolean
  parameter :structure_unit_id, String, allow_blank: false,
            schema: { format: "uuid", description: "a unit with a structure of its own, to change its unit types; the organisation's structure by default" }

  # @return [Hash] `{ level_id, name, effective_on, levels }`, levels top first, plus
  #   structure_unit_id when given
  def perform
    name = params[:name].strip
    taken = current_levels.find { |level| level.name.casecmp?(name) }
    raise Operations::Base::ParameterError, "There is already a unit type called #{taken.name}" if taken

    level_id = SecureRandom.uuid_v7
    refusing_as_parameter_errors { structure_handler.add_level(level_id, name, effective_on:, **stated_rules, **in_structure) }
    { level_id:, name:, **in_structure, effective_on:, levels: levels_payload }
  end

  private

  def stated_rules
    { parent_ids: params[:parent_ids]&.then { |ids| Array(ids).map { |id| id.to_s.downcase } }, top: params[:top] }
  end
end
