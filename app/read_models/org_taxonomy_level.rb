# frozen_string_literal: true

# One level of a tenant's structure taxonomy, such as "Department" or "Squad".
#
# Projected from TaxonomyDefined by {OrgGraph::Projections::Structure}. The
# primary key is the event-carried level id, kept through a rename; position
# orders the levels top first. Its provider supplies the level's units, and is
# Espalia until LevelProviderSet names another, with the HRIS field
# (provider_field) each person's unit at the level is read from. A level that
# states where its units may sit holds the rules in parent_level_ids and top.
#
class OrgTaxonomyLevel < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  has_many :units, class_name: "OrgUnit", foreign_key: :level_id, inverse_of: :level, dependent: nil

  scope :top_first, -> { order(:position) }

  # Where each kind of unit may sit, read the way the aggregate reads it.
  #
  # @param rows [Array<OrgTaxonomyLevel>] the levels, top first, when already loaded
  # @return [OrgGraph::Taxonomy]
  def self.taxonomy(rows = top_first.to_a)
    levels = rows.map do |level|
      rules = level.parent_level_ids.nil? ? {} : { parent_level_ids: level.parent_level_ids, top: level.top }
      { level_id: level.id, name: level.name, **rules }
    end
    OrgGraph::Taxonomy.new(levels, providers: rows.to_h { [ it.id, it.provider ] })
  end

  # Each level's rules as the payloads and forms read them.
  #
  # @param rows [Array<OrgTaxonomyLevel>] the levels, top first, when already loaded
  # @return [Hash{String => Hash}] level id => `{ parent_ids:, top: }`
  def self.rules_by_id(rows = top_first.to_a)
    taxonomy = taxonomy(rows)
    rows.to_h { [ it.id, taxonomy.kind(it.id).rules ] }
  end
end
