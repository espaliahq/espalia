# frozen_string_literal: true

# Merges one unit into another: everyone moves to the unit that carries on,
# and the merged unit retires.
class Operations::OrgGraph::MergeUnit < Operations::Base
  include Operations::OrgGraph::UnitWrite

  description "Merge a unit into another live unit from effective_on (today by default). Every membership " \
              "moves to into_unit_id, keeping its role and allocation, and unit_id retires, all under one " \
              "cause. A unit with live sub-units is refused, as is either unit when an HRIS supplies it. The " \
              "caller must be able to change both units."
  approval :in_app

  parameter :unit_id, String, required: true
  parameter :into_unit_id, String, required: true

  # @return [Hash] `{ unit_id, into_unit_id, memberships_moved, effective_on }`; the count leaves
  #   out leavers
  def perform
    unit = live_unit!(:unit_id)
    into = live_unit!(:into_unit_id)
    raise Operations::Base::ParameterError, "A unit can't merge into itself" if unit == into
    held_by_espalia!(unit)
    held_by_espalia!(into)
    without_live_children!(unit)
    moved = active_memberships(unit).count

    structure_handler(cause_id: SecureRandom.uuid_v7)
      .apply_succession(SecureRandom.uuid_v7, predecessor_ids: [ unit.id ], successor_ids: [ into.id ],
                                              effective_on: effective_on)
    { unit_id: unit.id, into_unit_id: into.id, memberships_moved: moved, effective_on: effective_on }
  end
end
