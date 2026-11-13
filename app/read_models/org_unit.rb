# frozen_string_literal: true

# A unit in a tenant's Org Graph structure: a department, a team, a squad.
#
# Projected from the tenant's OrgStructure stream by
# {OrgGraph::Projections::Structure}. The primary key is the event-carried
# unit id, which a rename or a move never changes. A retired unit keeps its
# row, with the date it ended.
#
class OrgUnit < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :parent, class_name: "OrgUnit", optional: true, inverse_of: :children
  belongs_to :level, class_name: "OrgTaxonomyLevel", optional: true, inverse_of: :units
  has_many :children, class_name: "OrgUnit", foreign_key: :parent_id, inverse_of: :parent, dependent: nil
  has_many :memberships, class_name: "OrgMembership", foreign_key: :unit_id, inverse_of: :unit, dependent: nil
  has_many :members, through: :memberships, source: :person
  has_many :predecessor_links, class_name: "OrgUnitSuccession", foreign_key: :successor_id,
                               inverse_of: :successor, dependent: nil
  has_many :successor_links, class_name: "OrgUnitSuccession", foreign_key: :predecessor_id,
                             inverse_of: :predecessor, dependent: nil
  has_many :owner_links, class_name: "OrgUnitOwner", foreign_key: :unit_id, inverse_of: :unit, dependent: nil
  has_many :predecessors, -> { distinct }, through: :predecessor_links
  has_many :successors, -> { distinct }, through: :successor_links

  scope :live, -> { where(retired_on: nil) }
  scope :roots, -> { where(parent_id: nil) }

  # @return [Boolean] whether Espalia holds the unit, so it can be edited here
  def held_by_espalia?
    provider == OrgGraph::StructureAggregate::ESPALIA
  end

  # @return [Boolean]
  def retired?
    retired_on.present?
  end

  # The unit's own stated owners who still work here. An owner who has left
  # stops counting the moment their `people` row goes inactive.
  #
  # @return [ActiveRecord::Relation<Person>]
  def own_owners
    Person.active.where(id: owner_links.select(:person_id))
  end

  # The people who own the unit: its own owners, or else its nearest
  # ancestor's.
  #
  # @return [ActiveRecord::Relation<Person>] empty when no unit up the chain has one
  def owners
    ancestors_and_self.each do |unit|
      owners = unit.own_owners
      return owners if owners.exists?
    end
    Person.none
  end

  # Whether the unit needs an owner named: its last owner was removed or has
  # left, or nobody up its chain owns it. It still resolves to an ancestor's
  # owners meanwhile.
  #
  # @return [Boolean]
  def needs_owner?
    return true unless owners.exists?

    !own_owners.exists? && (owners_lost_on.present? || owner_links.exists?)
  end

  # Whether the person, still working here, owns this unit or any unit above
  # it. Owning a unit covers everything beneath it, even a unit with owners of
  # its own.
  #
  # @param person [Person, nil]
  # @return [Boolean]
  def owned_by?(person)
    return false unless person&.status == "active"

    OrgUnitOwner.exists?(person_id: person.id, unit_id: ancestors_and_self.map(&:id))
  end

  private

  def ancestors_and_self
    Enumerator.new do |units|
      unit = self
      while unit
        units << unit
        unit = unit.parent
      end
    end
  end
end
