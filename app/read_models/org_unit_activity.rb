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

  # Every event carries a correlation id; the event's own id stands in for one
  # recorded without.

  # A unit's activity, newest first by when the Org Graph learned of it.
  #
  # @param unit_id [String]
  # @return [ActiveRecord::Relation<OrgUnitActivity>]
  def self.for_unit(unit_id)
    where(unit_id: unit_id.to_s.downcase).order(position: :desc)
  end

  # A unit's activity with the entries of one cause folded into one group,
  # newest first by each group's latest entry. A page never splits a group.
  #
  # @param unit_id [String]
  # @param page [Integer] from 1
  # @param per_page [Integer] groups per page
  # @return [Array<OrgUnitActivity::Group>]
  def self.feed(unit_id, page: 1, per_page: 25)
    causes = for_unit(unit_id).reorder(Arel.sql("MAX(position) DESC")).group(:cause_id)
                              .offset((page - 1) * per_page).limit(per_page).pluck(:cause_id)
    parts = for_unit(unit_id).where(cause_id: causes).group_by(&:cause_id)
    causes.map { |cause| OrgUnitActivity::Group.new(parts.fetch(cause)) }
  end

  # Every entry, in any unit, written under one cause.
  #
  # @param cause_id [String]
  # @return [ActiveRecord::Relation<OrgUnitActivity>]
  def self.caused_by(cause_id)
    where(cause_id: cause_id.to_s).order(position: :desc)
  end

  # @return [Boolean]
  def reversible? = REVERSIBLE.include?(event_type)

  # @param apart_from [String, nil] a cause whose own later changes don't count
  # @return [Boolean] true when nothing has changed the same fact since
  def latest?(apart_from: nil)
    later = self.class.where(unit_id:, subject:).where(position: (position + 1)..)
    later = later.where.not(cause_id: apart_from) if apart_from
    !later.exists?
  end

  # @return [Boolean]
  def changed_back? = changed_back_by_id.present?
end
