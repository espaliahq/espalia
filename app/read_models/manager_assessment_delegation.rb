# frozen_string_literal: true

# Projection read model for a grant of manager-rating authority to another
# person, for one report on one framework.
#
# One row per (tenant, person, framework, delegate_person_id). Materialised
# from `ManagerRatingDelegated` / `ManagerRatingDelegationRevoked` events by
# {PersonDevelopment::Projections::AssessmentAuthority}.
#
# A delegate may record manager ratings (gated by {AssessmentPolicy}) but may
# NOT start, complete, or record alignment — those stay manager-only. Revoke is
# non-destructive: ratings the delegate already made remain, attributed to them.
#
# @see PersonDevelopment::Projections::AssessmentAuthority
class ManagerAssessmentDelegation < ApplicationRecord
  STATUSES = %w[active revoked].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :delegate, class_name: "Person",
             foreign_key: :delegate_person_id, inverse_of: false, optional: true
  belongs_to :granted_by, class_name: "Person",
             foreign_key: :granted_by_id, inverse_of: false, optional: true

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :delegate_person_id, presence: true
  validates :granted_by_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  # Delegations that currently confer authority: status "active" and not past
  # their optional expiry. Lazy expiry — no background job revokes them.
  scope :active, lambda {
    where(status: "active")
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
  }
  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :for_delegate, ->(delegate_person_id) { where(delegate_person_id: delegate_person_id) }
  scope :for_assignment, lambda { |assignment|
    for_person(assignment.person_id).for_framework(assignment.framework_id)
  }

  # People eligible to receive a delegation for `assignment`: everyone in the
  # tenant except the assessee, the granter, and current active delegates.
  # Single source of truth so the modal's initial render and the post-grant
  # re-render agree on the candidate set.
  #
  # @param assignment [PersonFrameworkAssignment]
  # @param actor_person_id [String] the granter (excluded from candidates)
  # @return [ActiveRecord::Relation<Person>]
  def self.candidate_people(assignment:, actor_person_id:)
    excluded = active.for_assignment(assignment).pluck(:delegate_person_id)
    excluded << assignment.person_id
    excluded << actor_person_id
    Person.where.not(id: excluded.compact.uniq).order(:name)
  end

  # Whether `delegate_person_id` currently holds an active delegation to rate
  # `person_id` on `framework_id`.
  #
  # @return [Boolean]
  def self.active_delegate?(person_id:, framework_id:, delegate_person_id:)
    active.for_person(person_id).for_framework(framework_id)
          .for_delegate(delegate_person_id).exists?
  end
end
