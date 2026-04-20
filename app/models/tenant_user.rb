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

  # Ensures this TenantUser has a linked Person — the invariant that lets
  # domain-authored columns (e.g. framework_suggested_edits.author_id) be
  # foreign keys to people(id). Returns the linked Person.
  #
  # Tries email-match first (e.g. HRIS-imported employees), falls back to
  # creating a minimal Person so seeds, invites, and first logins always
  # produce a resolvable author. Idempotent.
  #
  # Called from ApplicationController (web request) and db/seeds.rb.
  #
  # @return [Person]
  def ensure_person!
    return person if person_id.present?

    ActsAsTenant.with_tenant(tenant) do
      linked = Person.create_or_find_by!(tenant: tenant, email: user.email) do |p|
        p.name = self.class.derive_person_name(user.email)
        p.status = "active"
      end
      update!(person: linked)
      linked
    end
  end

  # Derives a human-readable placeholder name from an email address by
  # splitting the local part on `.`, `_`, `-`, `+` and titleizing.
  #
  # @param email [String]
  # @return [String]
  def self.derive_person_name(email)
    local = email.to_s.split("@", 2).first.to_s.split("+", 2).first.to_s
    parts = local.split(/[._\-]/).reject(&:empty?)
    parts.map(&:capitalize).join(" ").presence || email
  end
end
