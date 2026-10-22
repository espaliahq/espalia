# frozen_string_literal: true

# A peer's acknowledgement that one of our evidence items was imported there:
# `remote_id` and `remote_url` say where it now lives. One row per item and
# consumer; a repeat updates the row (protocol §5.3).
#
# Not an event-sourced read model: the peer's POST writes it directly, and a
# rebuild of the evidence projection leaves it alone.
class FeedbackExchangeAck < ApplicationRecord
  MAX_ITEMS = 200
  MAX_FIELD_LENGTH = 2048

  acts_as_tenant :tenant

  belongs_to :tenant

  normalizes :consumer, with: ->(value) { value.to_s.strip.downcase }
  normalizes :remote_url, with: ->(value) { value.to_s.strip.presence }

  validates :evidence_id, :consumer, :remote_id, presence: true
  validates :remote_id, length: { maximum: MAX_FIELD_LENGTH }
  validates :remote_url, length: { maximum: MAX_FIELD_LENGTH }
  validate :remote_url_is_http, if: -> { remote_url.present? }

  scope :for_consumer, ->(consumer) { where(consumer: consumer) }

  # Records a page of acknowledgements. Items whose id is not one of this
  # tenant's evidence items are skipped: the peer may ack something we have
  # since lost, and that is no reason to fail the page.
  #
  # @param consumer [String] the acknowledging system's name
  # @param items [Array<Hash>] `id`, `remote_id` and optional `remote_url` each
  # @return [Boolean] false, with nothing written, when any item is malformed
  def self.record_all(consumer:, items:)
    return false if items.size > MAX_ITEMS

    acks = items.map do |item|
      new(evidence_id: item[:id], consumer: consumer, remote_id: item[:remote_id], remote_url: item[:remote_url])
    end
    return false unless acks.all?(&:valid?)

    known = EvidenceItem.where(id: acks.map(&:evidence_id)).pluck(:id).to_set
    # One row per item: Postgres refuses an upsert that touches a row twice, so a
    # page that names an item twice keeps its last word.
    rows = acks.select { |ack| known.include?(ack.evidence_id) }.index_by(&:evidence_id).values.map do |ack|
      ack.attributes.slice("evidence_id", "consumer", "remote_id", "remote_url")
         .merge("id" => SecureRandom.uuid_v7, "tenant_id" => ActsAsTenant.current_tenant.id)
    end
    return true if rows.empty?

    upsert_all(rows, unique_by: :idx_feedback_exchange_acks_item_consumer,
                     update_only: %i[remote_id remote_url])
    true
  end

  # @return [String, nil] the peer's address, only when it is safe to link to
  def safe_remote_url
    remote_url if remote_url.present? && !remote_url_invalid?
  end

  private

  def remote_url_invalid?
    uri = URI.parse(remote_url)
    !(%w[http https].include?(uri.scheme) && uri.host.present?)
  rescue URI::InvalidURIError
    true
  end

  # The URL is shown to people as a link, so only http(s) is allowed.
  def remote_url_is_http
    errors.add(:remote_url, "must be an http(s) URL") if remote_url_invalid?
  end
end
