# frozen_string_literal: true

# An organisational entity representing a person in the org chart.
#
# A Person may be created by HRIS sync or manually. They are linked to a User
# (via TenantUser) for authentication, but many Persons won't have a corresponding
# User (e.g. HRIS-imported people who haven't logged in yet).
#
# @example
#   person = Person.new(email: "alice@example.com", tenant: tenant)
#   person.name = "Alice Smith"
#
class Person < ApplicationRecord
  acts_as_tenant :tenant

  include HasTypeId
  has_typeid :per

  belongs_to :tenant
  belongs_to :manager, class_name: "Person", optional: true
  has_many :direct_reports, class_name: "Person", foreign_key: :manager_id, dependent: :nullify, inverse_of: :manager
  has_one :tenant_user, dependent: :nullify
  has_one :user, through: :tenant_user

  scope :active, -> { where(status: "active") }
  scope :inactive, -> { where(status: "inactive") }
  scope :hris_managed, -> { where.not(hris_source: nil) }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :status, inclusion: { in: %w[active inactive] }

  # The User used to deliver a notification directed at this person, lazily
  # provisioning one (with the linking TenantUser) when none exists yet — so a
  # notification reaches an HRIS-imported person who has never logged in. The
  # account starts with a random password; the person claims it later via
  # password reset or Google SSO (both match on email), and an existing-but-
  # unlinked membership is adopted rather than duplicated. Idempotent and safe
  # under concurrent provisioning.
  #
  # @return [User]
  def ensure_user!
    existing = user
    return existing if existing

    ActsAsTenant.with_tenant(tenant) do
      User.transaction do
        account = User.find_or_create_by!(email: email.to_s.downcase) { |u| u.password = SecureRandom.hex(24) }
        membership = TenantUser.find_or_initialize_by(tenant: tenant, user: account)
        membership.person ||= self
        membership.role ||= :member
        membership.save!
        account
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent provision won the race; re-resolve the now-linked user.
    reload
    user || raise
  end

  # The transitive closure of `manager_id` upward — direct manager,
  # skip-level, skip-skip, etc. Used by {EvidencePolicy} to gate
  # access to anyone in the hierarchy above the assessee.
  #
  # Detects cycles defensively: if the graph contains a loop (data bug)
  # the walk stops at the first repeated person rather than spinning.
  #
  # @return [Array<Person>] managers ordered closest-first; empty when
  #   the person has no manager set
  def manager_chain
    chain = []
    seen = Set.new([ id ])
    current = manager
    while current && !seen.include?(current.id)
      chain << current
      seen << current.id
      current = current.manager
    end
    chain
  end

  # Whether the given person is anywhere in this person's manager
  # hierarchy (direct manager, skip-level, etc.).
  #
  # @param other [Person, nil]
  # @return [Boolean]
  def managed_by?(other)
    return false if other.nil?

    manager_chain.any? { |m| m.id == other.id }
  end

  # All people anywhere below this person in the org chart — direct reports,
  # their reports, and so on — resolved in a single recursive query and scoped
  # to this person's tenant. Returned as a relation for composability
  # (e.g. chaining further `where`s).
  #
  # Cycle-safe: the recursive `UNION` stops re-adding already-seen ids, and the
  # result excludes the person themselves — a defensive guard against a manager
  # loop that points back at the root (mirrors {#manager_chain}'s guard).
  #
  # @return [ActiveRecord::Relation<Person>] descendants; never includes self
  def all_reports
    sql = <<~SQL.squish
      WITH RECURSIVE report_tree AS (
        SELECT id FROM people
        WHERE manager_id = :root_id AND tenant_id = :tenant_id
        UNION
        SELECT p.id FROM people p
        INNER JOIN report_tree rt ON p.manager_id = rt.id
        WHERE p.tenant_id = :tenant_id
      )
      SELECT id FROM report_tree WHERE id != :root_id
    SQL
    ids = self.class.connection.select_values(
      self.class.sanitize_sql_array([ sql, { root_id: id, tenant_id: tenant_id } ])
    )
    self.class.where(id: ids)
  end

  # Whether anyone in this person's org subtree has reports of their own —
  # the "manager of managers" shape that qualifies someone to facilitate
  # calibration sessions. all_reports is transitive, so any person managed
  # by a subtree member implies subtree depth ≥ 2. The single source for
  # this predicate — CalibrationSessionPolicy and the nav link both read it.
  #
  # @return [Boolean]
  def manages_managers?
    self.class.where(manager_id: all_reports.select(:id)).exists?
  end
end
