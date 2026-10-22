# frozen_string_literal: true

# Pulls one tenant's peer feed and deletions feed into GrowthOS (protocol §5).
#
# Each run first retries the records the ledger skipped for reasons our side
# can fix, then, page by page: imports every record, acknowledges the ones that
# now live here, and only then moves the cursor. A run that dies part way
# through a page redoes that page next time; the ledger makes that safe.
#
# Retries follow HrisSyncJob: a rate limit or a peer error is retried with
# backoff; a rejected signature is discarded, since a human has to fix it. A 404
# means the peer has the exchange off, so the run stops without a retry, and a
# 409 to an ack is logged as the bug it is while the run carries on.
#
# @example
#   FeedbackExchange::SyncJob.perform_later(tenant)
class FeedbackExchange::SyncJob < ApplicationJob
  PAGE_SIZE = 100
  # Bounds one run; the next run carries on from the cursor.
  MAX_PAGES = 50

  queue_as :default

  # Two runs for one tenant would race the same records and the cursor.
  limits_concurrency to: 1, key: ->(tenant) { tenant.id }, duration: 15.minutes

  retry_on FeedbackExchange::Errors::RateLimitError, wait: :polynomially_longer, attempts: 5
  retry_on FeedbackExchange::Errors::ApiError, wait: :polynomially_longer, attempts: 3

  discard_on FeedbackExchange::Errors::AuthenticationError do |job, error|
    Rails.logger.error("[FeedbackExchange::SyncJob] The peer rejected our signature for tenant #{job.arguments.first.id}: #{error.message}")
  end

  # Declared after the ApiError retry so it wins for this subclass.
  discard_on FeedbackExchange::Errors::PeerDisabled do |job, _error|
    Rails.logger.warn("[FeedbackExchange::SyncJob] The peer answered 404 for tenant #{job.arguments.first.id}: its exchange is " \
                      "switched off, or base_url misses its path prefix. Stopping this run.")
  end

  # @param tenant [Tenant]
  # @param client [FeedbackExchange::Client, nil] injectable for tests
  def perform(tenant, client: nil)
    return unless tenant.feedback_exchange_config.configured?(tenant)

    ActsAsTenant.with_tenant(tenant) do
      @tenant = tenant
      @client = client || FeedbackExchange::Client.for(tenant)
      @importer = FeedbackExchange::Importer.new(tenant)

      acknowledge(@importer.retry_skipped)
      pull(:cursor) { |since| @client.feedback(since: since, limit: PAGE_SIZE) }
        .then { |count| Rails.logger.info("[FeedbackExchange::SyncJob] Tenant #{tenant.id}: #{count} records") }
      pull(:deletions_cursor) { |since| @client.deletions(since: since, limit: PAGE_SIZE) }
      tenant.update_feedback_exchange!(settings: { last_synced_at: Time.current })
    end
  end

  private

  # @return [Integer] records processed
  def pull(cursor_key)
    since = @tenant.feedback_exchange_config.public_send(cursor_key)
    processed = 0
    MAX_PAGES.times do
      page = yield(since)
      items = Array(page["items"])
      cursor_key == :cursor ? import_page(items) : withdraw_page(items)
      processed += items.size

      next_cursor = page["next_cursor"].presence
      if page["has_more"] && next_cursor == since
        raise FeedbackExchange::Errors::ApiError.new(status: 200, message: "The peer said it had more but did not move its cursor")
      end
      if next_cursor && next_cursor != since
        @tenant.update_feedback_exchange!(settings: { cursor_key => next_cursor })
        since = next_cursor
      end
      break unless page["has_more"] && next_cursor
    end
    processed
  end

  def import_page(items)
    acknowledge(items.map { |record| @importer.import(record) }, items)
  end

  def withdraw_page(items)
    items.each { |deletion| @importer.withdraw_deleted(deletion["id"]) }
  end

  # Tells the peer where each record it sent now lives (protocol §5.3), so it
  # can link to it and never send it back to us.
  def acknowledge(results, records = nil)
    ids = records ? records.map { |record| record["id"].to_s } : external_ids_for(results)
    acks = results.zip(ids).filter_map do |result, external_id|
      next unless result.lives_here?

      { id: external_id, remote_id: result.evidence_id, remote_url: absolute_url("/assessments/#{result.assignment_id}") }
    end
    @client.ack(acks) if acks.any?
  rescue FeedbackExchange::Errors::Conflict => e
    Rails.logger.error("[FeedbackExchange::SyncJob] The peer refused our ack for tenant #{@tenant.id}: #{e.message}")
  end

  def external_ids_for(results)
    by_evidence = FeedbackExchangeImport.where(evidence_id: results.map(&:evidence_id).compact).pluck(:evidence_id, :external_id).to_h
    results.map { |result| by_evidence[result.evidence_id] }
  end

  def absolute_url(path)
    options = Rails.application.config.action_mailer.default_url_options || {}
    return path if options[:host].blank?

    scheme = options[:protocol] || (Rails.env.production? ? "https" : "http")
    port = options[:port] ? ":#{options[:port]}" : ""
    "#{scheme}://#{options[:host]}#{port}#{path}"
  end
end
