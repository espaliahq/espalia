# frozen_string_literal: true

# Retires a unit Espalia holds, ending every membership in it.
class Operations::OrgGraph::RetireUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Retire a unit in the Org Graph from effective_on (today by default), ending every membership " \
              "in it, so its people show as in no team. A unit with live sub-units is refused until they are " \
              "moved or retired, and one an HRIS supplies is retired in the HRIS. Refused unless the caller " \
              "is a tenant admin, an Org Graph editor or an owner of the unit or a unit above it."
  approval :in_app

  parameter :unit_id, String, required: true

  # @return [Hash] `{ unit_id, memberships_ended, effective_on }`; the count leaves out leavers
  def perform
    unit = live_unit!(:unit_id)
    held_by_espalia!(unit)
    without_live_children!(unit)
    ended = active_memberships(unit).count

    structure_handler(cause_id: SecureRandom.uuid_v7).retire_unit(unit.id, effective_on: effective_on)
    { unit_id: unit.id, memberships_ended: ended, effective_on: effective_on }
  end
end
