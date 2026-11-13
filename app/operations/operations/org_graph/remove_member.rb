# frozen_string_literal: true

# Ends a person's membership of a unit. effective_on is their last day there.
class Operations::OrgGraph::RemoveMember < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "End a person's membership of a unit in the Org Graph; effective_on (today by default) is " \
              "their last day in it. A membership an HRIS supplies ends in the HRIS, not here."
  approval :mcp_client

  parameter :person_id, String, required: true
  parameter :unit_id, String, required: true

  # @return [Hash] `{ person_id, unit_id, effective_on }`
  def perform
    person = person!(:person_id)
    unit = live_unit!(:unit_id)

    person_handler.end_membership(person.id, unit.id, provider: ::OrgGraph::StructureAggregate::ESPALIA,
                                  effective_on: effective_on)
    { person_id: person.id, unit_id: unit.id, effective_on: effective_on }
  end
end
