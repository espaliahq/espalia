# frozen_string_literal: true

# Places a person in a unit by hand. A unit an HRIS supplies takes people
# the HRIS doesn't know, and the sync leaves them be (#115).
class Operations::OrgGraph::AddMember < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Place a person in a live unit of the Org Graph, from effective_on (today by default), with an " \
              "optional role and allocation (greater than 0, at most 1). A person can be in several units. " \
              "A unit an HRIS supplies takes only people that HRIS doesn't hold; place the others in the HRIS. " \
              "Someone already in the unit is refused."
  approval :mcp_client

  parameter :unit_id, String, required: true
  parameter :person_id, String, required: true
  parameter :role, String
  parameter :allocation, Numeric

  # @return [Hash] `{ unit_id, person_id, role, allocation, effective_on }`
  def perform
    unit = live_unit!(:unit_id)
    person = person!(:person_id)
    if OrgMembership.exists?(person_id: person.id, unit_id: unit.id)
      raise Operations::Base::ParameterError, "#{person.name} is already in #{unit.name}"
    end
    allocation = params[:allocation]
    if allocation && !(allocation.positive? && allocation <= 1)
      raise Operations::Base::ParameterError, "allocation must be greater than 0 and at most 1"
    end

    role = params[:role].presence
    person_handler.set_membership(person.id, unit.id, provider: ::OrgGraph::StructureAggregate::ESPALIA,
                                  role: role, allocation: allocation, effective_on: effective_on)
    { unit_id: unit.id, person_id: person.id, role: role, allocation: allocation, effective_on: effective_on }
  end
end
