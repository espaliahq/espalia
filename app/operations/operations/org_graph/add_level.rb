# frozen_string_literal: true

# Adds a level Espalia holds at the bottom of the tenant's taxonomy.
class Operations::OrgGraph::AddLevel < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::TaxonomyWrite

  description "Add a level to the bottom of the Org Graph's taxonomy, from effective_on (today by default). " \
              "Espalia holds the new level; use org_graph_reorder_levels to move it up. Level names are " \
              "unique, ignoring case. Refused unless the caller is a tenant admin."
  approval :in_app

  parameter :name, String, required: true, allow_blank: false

  # @return [Hash] `{ level_id, name, effective_on, levels }`, levels top first
  def perform
    name = params[:name].strip
    taken = current_levels.find { |level| level.name.casecmp?(name) }
    raise Operations::Base::ParameterError, "There is already a level called #{taken.name}" if taken

    level_id = SecureRandom.uuid_v7
    refusing_as_parameter_errors { structure_handler.add_level(level_id, name, effective_on:) }
    { level_id:, name:, effective_on:, levels: levels_payload }
  end
end
