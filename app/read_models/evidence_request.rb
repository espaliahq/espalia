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

  # DOM id of this request's card on the evidence hub — the anchor that
  # notification deep links target. Single source of truth for the view and
  # the notifiers so the link can't drift from the element.
  #
  # @param id [String]
  # @return [String]
  def self.dom_id(id)
    "evidence-request-#{id}"
  end

  # Path to a request's card on the evidence hub (the notification deep-link
  # target), falling back to the hub itself when no id is given.
  #
  # @param id [String, nil]
  # @return [String]
  def self.hub_path(id)
    id.present? ? "/evidence##{dom_id(id)}" : "/evidence"
  end

  # @return [String]
  def dom_id
    self.class.dom_id(id)
  end
end
