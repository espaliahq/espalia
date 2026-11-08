# frozen_string_literal: true

# The feedback exchange consumer's ledger: one row per record a peer has sent,
# keyed on (origin, external_id) as the protocol requires (§2.4), saying what
# became of it. Written only by {FeedbackExchange::Importer}.
#
# A record skipped for a reason that can change on our side (the person is not
# in Espalia yet, is inactive, or has no assignment) keeps the record itself
# in `record`, so the importer can retry it without pulling it again. Every
# other row keeps no copy: the feedback lives on the evidence item.
class FeedbackExchangeImport < ApplicationRecord
  STATUSES = %w[imported updated skipped withdrawn].freeze

  SKIP_REASONS = %w[
    author_unmatched
    author_inactive
    recipient_unmatched
    recipient_inactive
    self_feedback
    audience_too_narrow
    kind_not_imported
    no_assignment
    echo
    invalid_record
  ].freeze

  # Reasons that depend on our people and assignments rather than on the record.
  RETRIABLE_REASONS = %w[author_unmatched author_inactive recipient_unmatched recipient_inactive no_assignment].freeze

  acts_as_tenant :tenant
  belongs_to :tenant

  validates :origin, :external_id, :synced_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :skip_reason, inclusion: { in: SKIP_REASONS }, if: -> { status == "skipped" }
  validates :skip_reason, absence: true, unless: -> { status == "skipped" }

  scope :skipped, -> { where(status: "skipped") }
  scope :retriable, -> { skipped.where(skip_reason: RETRIABLE_REASONS).where.not(record: nil) }
  scope :for_origin, ->(origin) { where(origin: origin) }

  # How many records ended in each state, and how many were skipped for each reason.
  #
  # @return [Hash] { imported:, updated:, withdrawn:, skipped:, skip_reasons: { reason => count } }
  def self.summary
    by_status = group(:status).count
    {
      imported: by_status.fetch("imported", 0),
      updated: by_status.fetch("updated", 0),
      withdrawn: by_status.fetch("withdrawn", 0),
      skipped: by_status.fetch("skipped", 0),
      skip_reasons: skipped.group(:skip_reason).count.sort.to_h
    }
  end

  # The people a peer named that Espalia could not find, from the records
  # skipped for that reason, most often seen first.
  #
  # @return [Array<Hash>] { email:, display_name:, role: "author" | "recipient", records: }
  def self.unmatched_people
    skipped.where(skip_reason: %w[author_unmatched recipient_unmatched]).where.not(record: nil)
      .pluck(:skip_reason, :record)
      .group_by { |reason, record| [ reason, record.dig(role_key(reason), "email").to_s.downcase ] }
      .map do |(reason, email), rows|
        { email: email, display_name: rows.first.last.dig(role_key(reason), "display_name"),
          role: role_key(reason), records: rows.size }
      end
      .sort_by { |person| [ -person[:records], person[:email] ] }
  end

  def self.role_key(reason)
    reason == "author_unmatched" ? "author" : "recipient"
  end
  private_class_method :role_key
end
