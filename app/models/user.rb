# frozen_string_literal: true

# Authentication identity for a GrowthOS user.
#
# User holds global Devise credentials. It is NOT tenant-scoped — the same
# User can belong to multiple tenants via TenantUser join records. Tenant
# context (role, linked Person) lives on TenantUser, not here.
#
# @example
#   user = User.new(email: "alice@example.com", password: "s3cr3t")
#
class User < ApplicationRecord
  has_prefix_id :usr

  has_many :tenant_users, dependent: :destroy
  has_many :tenants, through: :tenant_users

  # Include default devise modules. :validatable is included because email
  # uniqueness is now global (no tenant scope on User).
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable

  # @return [Boolean] whether this user has global admin privileges
  def global_admin?
    global_admin
  end
end
