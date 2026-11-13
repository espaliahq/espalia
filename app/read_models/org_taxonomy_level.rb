# frozen_string_literal: true

# One level of a tenant's structure taxonomy, such as "Department" or "Squad".
#
# Projected from TaxonomyDefined by {OrgGraph::Projections::Structure}. The
# primary key is the event-carried level id, kept through a rename; position
# orders the levels top first. Its provider supplies the level's units, and is
# Espalia until LevelProviderSet names another, with the HRIS field
# (provider_field) each person's unit at the level is read from.
#
class OrgTaxonomyLevel < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  has_many :units, class_name: "OrgUnit", foreign_key: :level_id, inverse_of: :level, dependent: nil

  scope :top_first, -> { order(:position) }
end
