# frozen_string_literal: true

# Says that a fact Espalia holds about a person is still true, which clears
# its stale flag (#142). A membership names its unit; any other fact is one
# of the person's own, such as their title or site.
class Operations::OrgGraph::ConfirmFact < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Confirm that a fact Espalia holds about a person is still true, so it is no longer stale. " \
              "A membership names its unit in unit_id; any other fact is the person's own. " \
              "A fact an HRIS supplies is confirmed by each sync and can't be confirmed here. " \
              "A confirmation is dated the day it is made."
  approval :mcp_client
  # The fact's age is read from when the confirmation happened, so a date the caller names would be ignored.
  parameters.delete(:effective_on)

  parameter :person_id, String, required: true
  parameter :fact, String, required: true, allowed: OrgGraph::PersonAggregate.confirmable_facts
  parameter :unit_id, String, allow_blank: false
  requires_when :unit_id, if: :fact, equals: OrgGraph::FactConfirmation::MEMBERSHIP
  forbids_when :unit_id, if: :fact, in: OrgGraph::PersonAggregate.confirmable_facts.excluding(OrgGraph::FactConfirmation::MEMBERSHIP)

  # @return [Hash] `{ person_id, fact, unit_id, confirmed_on }`
  def perform
    person = person!(:person_id)
    fact = params[:fact]
    unit_id = live_unit!(:unit_id).id if fact == ::OrgGraph::FactConfirmation::MEMBERSHIP

    confirmed_on = Date.current.iso8601
    person_handler.confirm_fact(person.id, fact, unit_id:, effective_on: confirmed_on)
    { person_id: person.id, fact:, unit_id:, confirmed_on: }
  end
end
