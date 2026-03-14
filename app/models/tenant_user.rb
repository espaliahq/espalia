# frozen_string_literal: true

# Represents a user's membership in a tenant.
#
# TenantUser is the join record between a global User (Devise identity) and a
# Tenant (organisation). It carries the user's role within that tenant and an
# optional link to the Person domain entity for that tenant.
#
# A user may have multiple TenantUser records (one per tenant they belong to).
#
# @example
#   tenant_user = TenantUser.create!(tenant: tenant, user: user, role: :admin)
#
class TenantUser < ApplicationRecord
  acts_as_tenant :tenant

  has_prefix_id :tnu

  ROLES = { member: "member", admin: "admin" }.freeze

  belongs_to :tenant
  belongs_to :user
  belongs_to :person, optional: true

  enum :role, ROLES, default: :member

  validates_uniqueness_to_tenant :user_id
  validates :role, presence: true
end
