# frozen_string_literal: true

# Moves a person's membership from one unit to another, keeping its terms.
class Operations::OrgGraph::MoveMember < Operations::Base
  include Operations::OrgGraph::UnitWrite
  prepend Operations::OrgGraph::PlanWrite

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

    with_membership(person, from) do |provider|
      ensure_held_by_espalia!(person, from, provider)
      person_handler.move_membership(person.id, from.id, to.id, effective_on: effective_on, **plan)
    end
    { person_id: person.id, from_unit_id: from.id, unit_id: to.id, effective_on: effective_on }
  end

  private

  # The command handler can't refuse this: the HRIS mirror moves its own
  # memberships through the same command.
  def ensure_held_by_espalia!(person, unit, provider)
    raise Operations::Base::ParameterError, "#{person.name} isn't in #{unit.name}" unless provider
    return if provider == ::OrgGraph::StructureAggregate::ESPALIA

    raise Operations::Base::ParameterError,
          "#{HrisConfig.provider_label(provider)} supplies #{person.name}'s place in #{unit.name}; move it there"
  end
end
