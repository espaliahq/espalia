# frozen_string_literal: true

# Moves a unit Espalia holds beneath another unit, or to the top.
class Operations::OrgGraph::MoveUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite
  include Operations::OrgGraph::PlanWrite

  description "Move a unit in the Org Graph beneath another live unit at a higher level, or to the top " \
              "when parent_id is omitted, from effective_on (today by default). Only a unit Espalia holds " \
              "can be moved here. Moving a unit changes who inherits its ownership, so the caller needs " \
              "rights on the unit and where it lands."
  approval :in_app

  parameter :unit_id, String, required: true
  parameter :parent_id, String, allow_blank: false

  # @return [Hash] `{ unit_id, parent_id, effective_on }`
  def perform
    unit = live_unit!(:unit_id)
    parent = params[:parent_id] && live_unit!(:parent_id)

    structure_handler.move_unit(unit.id, parent&.id, effective_on: effective_on, **plan)
    { unit_id: unit.id, parent_id: parent&.id, effective_on: effective_on }
  end
end
