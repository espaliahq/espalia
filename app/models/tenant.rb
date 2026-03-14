# frozen_string_literal: true

# Represents an organisation using GrowthOS.
#
# Tenants are the root of the multi-tenancy model. All user and domain data
# is scoped to a tenant via acts_as_tenant row-level isolation.
#
# @example
#   tenant = Tenant.create!(name: "ACME Corp", slug: "acme-corp")
#
class Tenant < ApplicationRecord
  has_many :tenant_users, dependent: :destroy
  has_many :users, through: :tenant_users
  has_many :people, dependent: :destroy

  normalizes :slug, with: ->(s) { s.downcase.strip.gsub(/[^a-z0-9-]/, "-").gsub(/-+/, "-").delete_prefix("-").delete_suffix("-") }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "must contain only lowercase letters, numbers, and dashes" }
end
