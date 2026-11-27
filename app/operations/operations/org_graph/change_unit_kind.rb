# frozen_string_literal: true

# Changes the type of a unit Espalia holds, keeping its name, place, owners
# and members ([#401](https://github.com/espaliahq/espalia/issues/401)).
# A type belongs to the structure in force where the unit sits, so retyping
# needs the right to change that structure, not just the unit.
class Operations::OrgGraph::ChangeUnitKind < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Change the unit type of a unit Espalia holds, from effective_on (today by default). The new type " \
              "must be one Espalia supplies, must be able to sit under the unit's parent (or at the top), and " \
              "every live sub-unit must be able to sit under it, on every day from effective_on, a move dated ahead included. " \
              "effective_on can't be after today or before the unit's last change of type. It needs the right to " \
              "change the structure in force where the unit sits: a tenant admin or an Org Graph editor for " \
              "any, and for a unit's own structure an owner of that unit or a unit above it, or anyone they report to."
  approval :in_app

  parameter :unit_id, String, required: true
  parameter :level_id, String, required: true, allow_blank: false

  # @return [Hash] `{ unit_id, level_id, previous_level_id, effective_on }`
  def perform
    unit = live_unit!(:unit_id)
    level_id = uuid!(:level_id).downcase
    on = effective_on

    refusing_as_parameter_errors { structure_handler.change_unit_kind(unit.id, level_id, effective_on: on) }
    { unit_id: unit.id, level_id:, previous_level_id: unit.level_id, effective_on: on }
  end
end
