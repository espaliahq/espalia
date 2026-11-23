# frozen_string_literal: true

# Changes the type of a unit Espalia holds, keeping its name, place, owners
# and members ([#401](https://github.com/espaliahq/espalia/issues/401)).
# The type belongs to the structure the unit sits in, so retyping needs the
# right to change that structure: an owner who may move a unit may not retype
# it, as a type decides what may sit above and below it.
class Operations::OrgGraph::ChangeUnitKind < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Change the unit type of a unit Espalia holds, from effective_on (today by default). The new type " \
              "must be one Espalia supplies, must be able to sit under the unit's parent (or at the top), and " \
              "every live sub-unit must be able to sit under it, on every day from effective_on, a move dated ahead included. " \
              "effective_on can't be after today or before the unit's last change of type. The type belongs to the " \
              "structure the unit sits in: a tenant admin or an Org Graph editor can change any, and an owner of the " \
              "unit that declares that structure or a unit above it, or anyone they report to, can change one in a " \
              "unit's own structure. Owning the unit alone is not enough."
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
