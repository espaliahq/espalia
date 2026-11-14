# frozen_string_literal: true

# Renames a unit Espalia holds. A unit an HRIS supplies keeps its HRIS name.
class Operations::OrgGraph::RenameUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite
  prepend Operations::OrgGraph::PlanWrite

  description "Rename a unit in the Org Graph, from effective_on (today by default). Only a unit Espalia " \
              "holds can be renamed here; one an HRIS supplies is renamed in the HRIS. Refused unless the " \
              "caller is a tenant admin, an Org Graph editor or an owner of the unit or a unit above it."
  approval :mcp_client

  parameter :unit_id, String, required: true
  parameter :name, String, required: true, allow_blank: false

  # @return [Hash] `{ unit_id, name, effective_on }`
  def perform
    unit = live_unit!(:unit_id)
    name = params[:name].strip
    raise Operations::Base::ParameterError, "name can't be blank" if name.empty?

    structure_handler.rename_unit(unit.id, name, effective_on: effective_on, **plan)
    { unit_id: unit.id, name: name, effective_on: effective_on }
  end
end
