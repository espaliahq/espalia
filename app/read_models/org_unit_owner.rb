# frozen_string_literal: true

# One of a unit's stated owners. A unit can have several, with none primary.
#
# Projected from UnitOwnerAdded and UnitOwnerRemoved by
# {OrgGraph::Projections::Structure}. The row goes when the owner is removed;
# the history stays in the stream.
#
class OrgUnitOwner < ApplicationRecord
  include DeterministicId
  deterministic_id_from :unit_id, :person_id

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :unit, class_name: "OrgUnit", inverse_of: :owner_links
  belongs_to :person, optional: true
end
