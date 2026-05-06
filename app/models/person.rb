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

  has_prefix_id :per

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

  # The transitive closure of `manager_id` upward — direct manager,
  # skip-level, skip-skip, etc. Used by {AssessmentPolicy} and
  # {EvidencePolicy} to gate access to anyone in the hierarchy above
  # the assessee.
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
end
