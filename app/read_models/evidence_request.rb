# frozen_string_literal: true

# Projection read model for a cell-scoped evidence request — an ask for peer
# evidence about one (capability, level) cell of a person's assessment.
#
# Materialised from the PersonDevelopment stream (EvidenceRequested /
# …Responded / …Declined / …Cancelled) by
# {PersonDevelopment::Projections::EvidenceRequests}. The PK is the
# event-carried `request_id`, so the row is replay-stable and safe to address
# from inbox links and Slack deep links.
#
# Lifecycle: pending → responded | declined | cancelled. Only `pending`
# requests are actionable; the others are terminal history.
class EvidenceRequest < ApplicationRecord
  STATUSES = %w[pending responded declined cancelled].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :requestee, class_name: "Person", foreign_key: :requestee_person_id, inverse_of: false, optional: false
  belongs_to :requester, class_name: "Person", foreign_key: :requested_by_id, inverse_of: false, optional: false
  belongs_to :assessee, class_name: "Person", foreign_key: :person_id, inverse_of: false, optional: false

  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :incoming_for, ->(person_id) { where(requestee_person_id: person_id) }
  scope :outgoing_for, ->(person_id) { where(requested_by_id: person_id) }
  scope :for_assessment, ->(person_id, framework_id) { where(person_id: person_id, framework_id: framework_id) }
  scope :recent_first, -> { order(requested_at: :desc) }

  # @return [Boolean] whether the request can still be acted on
  def pending?
    status == "pending"
  end
end
