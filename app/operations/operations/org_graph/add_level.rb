# frozen_string_literal: true

# Adds a level Espalia holds at the bottom of the tenant's taxonomy.
class Operations::OrgGraph::AddLevel < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Add a level to the bottom of the Org Graph's taxonomy, from effective_on (today by default). " \
              "Espalia holds the new level. parent_ids lists the level_ids it can sit under, and top whether " \
              "it can sit at the top (by default, only when parent_ids is empty); without either, it can sit " \
              "under every level above it or at the top. org_graph_set_kind_parents changes these later. " \
              "Level names are unique, ignoring case. Refused unless the caller is a tenant admin."
  approval :in_app

  parameter :name, String, required: true, allow_blank: false
  parameter :parent_ids, Array,
            schema: { type: "array", items: { type: "string" }, description: "level_ids the new level can sit under" }
  parameter :top, :boolean

  # @return [Hash] `{ level_id, name, effective_on, levels }`, levels top first
  def perform
    name = params[:name].strip
    taken = current_levels.find { |level| level.name.casecmp?(name) }
    raise Operations::Base::ParameterError, "There is already a level called #{taken.name}" if taken

    level_id = SecureRandom.uuid_v7
    refusing_as_parameter_errors { structure_handler.add_level(level_id, name, effective_on:, **stated_rules) }
    { level_id:, name:, effective_on:, levels: levels_payload }
  end

  private

  def stated_rules
    return {} if params[:parent_ids].nil? && params[:top].nil?

    parent_ids = Array(params[:parent_ids]).map { |id| id.to_s.downcase }
    { parent_ids:, top: params[:top].nil? ? parent_ids.empty? : params[:top] }
  end
end
