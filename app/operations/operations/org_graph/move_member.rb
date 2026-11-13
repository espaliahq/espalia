# frozen_string_literal: true

# Moves a person's membership from one unit to another, keeping its terms.
class Operations::OrgGraph::MoveMember < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Move a person's membership of one unit to another live unit, keeping its role and " \
              "allocation, from effective_on (today by default). A membership an HRIS supplies moves in " \
              "the HRIS, not here."
  approval :mcp_client

  parameter :person_id, String, required: true
  parameter :from_unit_id, String, required: true
  parameter :unit_id, String, required: true

  # @return [Hash] `{ person_id, from_unit_id, unit_id, effective_on }`
  def perform
    person = person!(:person_id)
    from = live_unit!(:from_unit_id)
    to = live_unit!(:unit_id)
    raise Operations::Base::ParameterError, "#{person.name} is already in #{to.name}" if from == to

    person_handler.move_membership(person.id, from.id, to.id, effective_on: effective_on)
    { person_id: person.id, from_unit_id: from.id, unit_id: to.id, effective_on: effective_on }
  end
end
