# frozen_string_literal: true

# A person's current membership of one unit, with their allocation and role.
#
# Projected from the person streams by {OrgGraph::Projections::Members}, and
# nothing else writes it. An ended membership has no row. The id derives from
# the person and the unit, so a rebuild keeps it.
#
class OrgMembership < ApplicationRecord
  include DeterministicId
  deterministic_id_from :person_id, :unit_id

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :unit, class_name: "OrgUnit", optional: true, inverse_of: :memberships
  belongs_to :person, optional: true

  scope :in_live_units, -> { joins(:unit).merge(OrgUnit.live) }
end
