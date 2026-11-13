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
  has_many :predecessor_links, class_name: "OrgUnitSuccession", foreign_key: :successor_id,
                               inverse_of: :successor, dependent: nil
  has_many :successor_links, class_name: "OrgUnitSuccession", foreign_key: :predecessor_id,
                             inverse_of: :predecessor, dependent: nil
  has_many :predecessors, through: :predecessor_links
  has_many :successors, through: :successor_links

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
end
