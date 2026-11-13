# frozen_string_literal: true

# Removes one of a unit's owners.
class Operations::OrgGraph::RemoveUnitOwner < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Remove a person from a live unit's owners in the Org Graph, from effective_on (today by " \
              "default). This takes away their rights over the unit and the units beneath it."
  approval :in_app

  parameter :unit_id, String, required: true
  parameter :person_id, String, required: true

  # @return [Hash] `{ unit_id, person_id, effective_on }`
  def perform
    unit = live_unit!(:unit_id)
    person = person!(:person_id)

    structure_handler.remove_unit_owner(unit.id, person.id, effective_on: effective_on)
    { unit_id: unit.id, person_id: person.id, effective_on: effective_on }
  end
end
