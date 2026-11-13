# frozen_string_literal: true

# Names a person as one of a unit's owners. Owners are Espalia's to state,
# so a unit an HRIS supplies takes them too.
class Operations::OrgGraph::AddUnitOwner < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Name a person as an owner of a live unit in the Org Graph, from effective_on (today by " \
              "default). An owner may change the unit and every unit beneath it, so this grants " \
              "permissions. Units an HRIS supplies take owners too."
  approval :in_app

  parameter :unit_id, String, required: true
  parameter :person_id, String, required: true

  # @return [Hash] `{ unit_id, person_id, effective_on }`
  def perform
    unit = live_unit!(:unit_id)
    person = person!(:person_id)
    raise Operations::Base::ParameterError, "#{person.name} has left" unless person.status == "active"

    structure_handler.add_unit_owner(unit.id, person.id, effective_on: effective_on)
    { unit_id: unit.id, person_id: person.id, effective_on: effective_on }
  end
end
