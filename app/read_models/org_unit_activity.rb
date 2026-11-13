# frozen_string_literal: true

# One change to a unit or to one of its memberships: who made it, or which
# provider, what changed from and to, when it took effect, and when the Org
# Graph learned of it. A move between units is an entry in each.
#
# Projected by {OrgGraph::Projections::UnitActivity}, and nothing else writes
# it. The id derives from the event and the unit, so a rebuild keeps it.
#
class OrgUnitActivity < ApplicationRecord
  include DeterministicId
  deterministic_id_from :event_id, :unit_id

  # The changes "change it back" can undo. Creating, retiring and succeeding
  # units reorganise the structure, so they aren't among them.
  REVERSIBLE = %w[
    MembershipSet MembershipEnded MembershipMoved UnitRenamed UnitMoved UnitOwnerAdded UnitOwnerRemoved
  ].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :unit, class_name: "OrgUnit", optional: true
  belongs_to :other_unit, class_name: "OrgUnit", optional: true
  belongs_to :person, optional: true
  belongs_to :actor, class_name: "Person", optional: true

  # A unit's activity, newest first by when the Org Graph learned of it.
  #
  # @param unit_id [String]
  # @return [ActiveRecord::Relation<OrgUnitActivity>]
  def self.for_unit(unit_id)
    where(unit_id: unit_id.to_s.downcase).order(position: :desc)
  end

  # @return [Boolean]
  def reversible? = REVERSIBLE.include?(event_type)

  # @return [Boolean] true when nothing has changed the same fact since
  def latest? = !self.class.where(unit_id:, subject:).where(position: (position + 1)..).exists?

  # @return [Boolean]
  def changed_back? = changed_back_by_id.present?
end
