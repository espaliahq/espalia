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

  include HasTypeId
  has_typeid :tnu

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
      transaction do
        tenant.lock!
        linked = Person.create_or_find_by!(tenant: tenant, email: user.email) do |p|
          p.name = self.class.derive_person_name(user.email)
          p.status = "active"
        end
        record_in_org_graph(linked) if tenant.org_graph_people_projected?
        update!(person: linked)
        linked
      end
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

  private

  # A tenant cut over to the Org Graph projects its people's columns from
  # their streams, so a person who has none starts one from their row. The
  # tenant lock keeps a cut-over from slipping in between. The system records
  # them, as it creates their row: most calls come from a member's own first
  # sign-in, and only an admin or an Org Graph editor may record a person.
  #
  # A refused recording is reported and the link kept, so it never fails a
  # sign-in. The row keeps its values, since a rebuild leaves anyone with no
  # stream alone, and the next HRIS sync records a person it supplies.
  def record_in_org_graph(person)
    transaction(requires_new: true) do
      next if Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id, tenant: tenant)).first

      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        .record_person(person.id, **OrgGraph::PeopleCutover.row_facts(person))
    end
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { tenant_id: tenant.id, person_id: person.id })
  end
end
