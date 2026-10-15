# frozen_string_literal: true

# Feedback written outside the app (Slack) by someone who cannot yet act in
# it: a Person known from HRIS with no sign-in. The draft keeps what they
# wrote until their first sign-in, when the hub opens the evidence modal
# prefilled from it. Bound to the author's email — only a session for that
# email may open it — and short-lived.
class FeedbackDraft < ApplicationRecord
  TTL = 14.days

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :recipient, class_name: "Person", foreign_key: :recipient_person_id, inverse_of: false, optional: true
  belongs_to :assignment, class_name: "PersonFrameworkAssignment", inverse_of: false, optional: true

  attribute :external_reference, ExternalReference.to_type, default: -> { ExternalReference.new }

  has_secure_token :token, length: 36

  normalizes :author_email, with: ->(e) { e.to_s.strip.downcase }

  validates :author_email, presence: true
  validates :content, presence: true
  validates :evidence_type, presence: true, inclusion: { in: EvidenceItem::EVIDENCE_TYPES }
  validates :expires_at, presence: true

  before_validation { self.expires_at ||= TTL.from_now }

  scope :open, -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }

  # @param token [String]
  # @param email [String] the signed-in user's email
  # @return [FeedbackDraft, nil] the open draft, only for its author
  def self.open_for(token:, email:)
    return nil if token.blank? || email.blank?

    open.find_by(token: token, author_email: email.to_s.strip.downcase)
  end

  # @return [String] the deep link a DM carries; the app's sign-in stores it
  #   and returns the author here afterwards
  def path
    "/evidence/drafts/#{token}"
  end

  def consume!
    update!(consumed_at: Time.current)
  end
end
