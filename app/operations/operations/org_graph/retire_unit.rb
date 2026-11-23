# frozen_string_literal: true

# Retires a unit Espalia holds, ending every membership in it.
#
# Approval is :in_app [#138](https://github.com/espaliahq/espalia/issues/138):
# it ends many memberships at once and can't be undone in one step. It runs
# under one new cause, so every event it writes shares a correlation id. A
# unit an HRIS mirrors is refused.
class Operations::OrgGraph::RetireUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite
  prepend Operations::OrgGraph::PlanWrite

  description "Retire a unit in the Org Graph from effective_on (today by default), ending every membership " \
              "in it. Its people with no other live unit then show as in no team. A unit with live sub-units " \
              "is refused until they are moved or retired, and one an HRIS supplies is retired in the HRIS. " \
              "Refused unless the caller is a tenant admin, an Org Graph editor, an owner of the unit or a unit " \
              "above it, or someone they report to."
  approval :in_app

  parameter :unit_id, String, required: true

  # @return [Hash] `{ unit_id, memberships_ended, effective_on }`; the count leaves out leavers
  def perform
    unit = live_unit!(:unit_id)
    held_by_espalia!(unit)
    without_live_children!(unit)
    ended = active_memberships(unit).count

    structure_handler(cause_id: SecureRandom.uuid_v7).retire_unit(unit.id, effective_on: effective_on, **plan)
    { unit_id: unit.id, memberships_ended: ended, effective_on: effective_on }
  end
end
