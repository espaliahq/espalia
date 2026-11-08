# frozen_string_literal: true

# A single field mapping from an HRIS source field to a Person attribute.
#
# Used within {HrisConfig} to allow tenants to customise how HRIS fields
# map to Espalia Person attributes beyond the built-in defaults.
#
# @example
#   HrisFieldMapping.new(hris_field: "work.customField", person_field: "department")
#
class HrisFieldMapping
  include StoreModel::Model

  attribute :hris_field, :string
  attribute :person_field, :string

  validates :hris_field, :person_field, presence: true
end
