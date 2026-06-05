# frozen_string_literal: true

# Projection read model recording who a person's reporting manager is, as a
# first-class fact on the PersonDevelopment stream.
#
# One row per (tenant, person, framework). Materialised from
# `ReportingManagerRecorded` events by
# {PersonDevelopment::Projections::AssessmentAuthority}.
#
# This is the **authoritative** source for "who may manager-rate" — both
# {AssessmentPolicy} and the PersonDevelopment aggregate read it. When no row
# exists (manual / non-HRIS tenant, or pre-backfill), callers fall back to the
# live `Person.manager_id`.
#
# @see PersonDevelopment::Projections::AssessmentAuthority
class RecordedReportingManager < ApplicationRecord
  SOURCES = %w[hris backfill].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :manager, class_name: "Person",
             foreign_key: :manager_id, inverse_of: false, optional: true

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :manager_id, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }

  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }

  # The recorded reporting manager id for a (person, framework), or nil when
  # nothing has been recorded yet (manual tenant / pre-backfill).
  #
  # @param person_id [String]
  # @param framework_id [String]
  # @return [String, nil]
  def self.manager_id_for(person_id, framework_id)
    for_person(person_id).for_framework(framework_id).pick(:manager_id)
  end
end
