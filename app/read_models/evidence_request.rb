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

  # ── Reminder timing policy (sweep job + manual nudges) ──
  # A pending request is automatically nudged once per kind: `no_response`
  # after 7 quiet days, `due_soon` 2 days before the optional due date —
  # whichever threshold is crossed first, never within 24h of the ask, never
  # twice within 3 days, and never for requests older than 30 days (so rollout
  # doesn't dredge up ancient asks). The requester may additionally nudge
  # manually (kind `manual`, repeatable) once NUDGE_GAP has passed since the
  # last reminder of any kind. The once-per-automatic-kind guarantee itself
  # lives in the aggregate; these constants are the when, not the whether.
  # Every reminder is appended to `reminder_history` and stamps
  # `last_reminded_at` (the projection writes both).
  REMINDER_KINDS = %w[no_response due_soon manual].freeze
  NO_RESPONSE_REMINDER_AFTER = 7.days
  DUE_SOON_REMINDER_WINDOW = 2.days
  MIN_REMINDER_REQUEST_AGE = 24.hours
  REMINDER_GAP = 3.days
  MAX_REMINDER_REQUEST_AGE = 30.days
  # A requester may manually nudge once the request has gone this long with
  # no reminder of any kind (automatic reminders count — they reset the clock).
  NUDGE_GAP = 2.days

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :cycle, class_name: "AssessmentCycle",
             primary_key: :cycle_id, foreign_key: :cycle_id,
             inverse_of: false, optional: true
  belongs_to :requestee, class_name: "Person", foreign_key: :requestee_person_id, inverse_of: false, optional: false
  belongs_to :requester, class_name: "Person", foreign_key: :requested_by_id, inverse_of: false, optional: false
  belongs_to :assessee, class_name: "Person", foreign_key: :person_id, inverse_of: false, optional: false

  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :resolved, -> { where.not(status: "pending") }
  scope :reminder_candidates, -> { pending.where(requested_at: MAX_REMINDER_REQUEST_AGE.ago..MIN_REMINDER_REQUEST_AGE.ago) }
  # Stalest first: least recently touched (requested or reminded) at the top,
  # so the requests most in need of attention lead the open lists.
  scope :least_recently_touched, -> { order(Arel.sql("GREATEST(requested_at, COALESCE(last_reminded_at, requested_at)) ASC")) }
  scope :incoming_for, ->(person_id) { where(requestee_person_id: person_id) }
  scope :outgoing_for, ->(person_id) { where(requested_by_id: person_id) }
  scope :for_assessment, ->(person_id, framework_id) { where(person_id: person_id, framework_id: framework_id) }
  scope :for_cycle, ->(cycle_id) { where(cycle_id: cycle_id) }
  scope :recent_first, -> { order(requested_at: :desc) }

  # @return [Boolean] whether the request can still be acted on
  def pending?
    status == "pending"
  end

  # Whether the requester may manually nudge the requestee right now: the
  # request is still open and NUDGE_GAP has passed since the last reminder of
  # any kind (or since the ask, when never reminded). `last_reminded_at` is a
  # projected column covering automatic reminders AND manual nudges.
  #
  # @param now [Time]
  # @return [Boolean]
  def can_nudge?(now: Time.current)
    pending? && now >= (last_reminded_at || requested_at) + NUDGE_GAP
  end

  # The reminder kind whose threshold has been crossed and not yet sent — nil
  # when nothing is due. When both kinds are due at once, the one whose
  # threshold came first wins; the REMINDER_GAP then holds the other back so
  # one request never pings twice in the same few days.
  #
  # @param now [Time]
  # @return [String, nil] "no_response" | "due_soon" | nil
  def due_reminder_kind(now: Time.current)
    return nil unless pending?
    return nil if now < requested_at + MIN_REMINDER_REQUEST_AGE
    return nil if last_reminded_at && now < last_reminded_at + REMINDER_GAP

    candidates = {}
    candidates["no_response"] = requested_at + NO_RESPONSE_REMINDER_AFTER if no_response_reminder_due?(now)
    candidates["due_soon"] = due_at - DUE_SOON_REMINDER_WINDOW if due_soon_reminder_due?(now)
    candidates.min_by { |_kind, threshold| threshold }&.first
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

  # Where a notification about a request lands: the hub finds the
  # conversation that holds it. Falls back to the hub when no id is given.
  #
  # @param id [String, nil]
  # @return [String]
  def self.hub_path(id)
    id.present? ? "/evidence/requests/#{id}" : "/evidence"
  end

  # @return [String]
  def dom_id
    self.class.dom_id(id)
  end

  private

  def no_response_reminder_due?(now)
    no_response_reminded_at.nil? && now >= requested_at + NO_RESPONSE_REMINDER_AFTER
  end

  # Only before the due date — chasing an already-missed deadline is a
  # different (out-of-scope) "overdue" concept, not a due-soon nudge.
  def due_soon_reminder_due?(now)
    due_soon_reminded_at.nil? && due_at.present? &&
      now >= due_at - DUE_SOON_REMINDER_WINDOW && now <= due_at
  end
end
