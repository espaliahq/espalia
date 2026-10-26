# frozen_string_literal: true

# One page of GrowthOS feedback for a peer system to pull (protocol §5.1).
#
# Reads {EvidenceItem} rows keyset-paged on `(updated_at, id)`, so an edit or a
# withdrawal comes back with a newer position and a row inserted mid-walk is
# never skipped. Runs inside the signing tenant's `ActsAsTenant` scope.
#
# What leaves is limited by who wrote it and where it already lives:
# - not the person's own self-assessment: `source: self`, or anything they
#   wrote about themselves (older answers to a request about their own
#   assessment carry a peer source);
# - only a person's own writing, not an HRIS, system or exchange import;
# - not what the asking consumer itself sent us (protocol §2.5), nor another
#   system's import it has since acknowledged;
# - only the kinds the tenant exports.
#
# The cursor is the last row read, so a row that commits late with an
# `updated_at` behind it (a long transaction that began before a faster one) is
# missed until the peer resets its cursor. Projection writes are short, so the
# window is small; it is the usual limit of keyset paging on a timestamp.
#
# Costs one query for the page and one each for the people, answered requests,
# cycles and assignments the records name, whatever the page size.
class FeedbackExchange::Feed
  DEFAULT_LIMIT = 100
  MAX_LIMIT = 200
  # Surfaces that record on nobody's behalf. Nil (history) passes: those rows
  # predate the column and were all written by a person.
  NON_HUMAN_VIA = %w[feedback_exchange hris system].freeze
  IMPORTED_VIA = "feedback_exchange"

  # A page of records, its cursor and whether more follow.
  Page = Data.define(:items, :next_cursor, :has_more)

  # @param consumer [String] the asking system's name
  # @param config [FeedbackExchangeConfig] the tenant's exchange settings
  # @param cursor [FeedbackExchange::FeedCursor, nil]
  # @param limit [Integer] clamped to {MAX_LIMIT}
  def initialize(consumer:, config:, cursor: nil, limit: DEFAULT_LIMIT)
    @consumer = consumer
    @config = config
    @cursor = cursor
    @limit = limit.clamp(1, MAX_LIMIT)
  end

  # @return [Page]
  def page
    rows = eligible.order(:updated_at, :id).limit(@limit + 1).to_a
    has_more = rows.size > @limit
    rows = rows.first(@limit)

    Page.new(
      items: FeedbackExchange::Record.for(rows),
      next_cursor: next_cursor(rows),
      has_more: has_more
    )
  end

  private

  # The position after this page: the last row read, emitted or not, so rows the
  # peer will never see do not hold its cursor back. An empty page keeps the
  # caller's own position.
  def next_cursor(rows)
    last = rows.last
    return @cursor&.encode if last.nil?

    FeedbackExchange::FeedCursor.new(updated_at: last.updated_at, id: last.id).encode
  end

  def eligible
    scope = EvidenceItem.where.not(source: "self")
                        .where("evidence_items.author_id <> evidence_items.person_id")
                        .where("evidence_items.recorded_via IS NULL OR evidence_items.recorded_via NOT IN (?)", NON_HUMAN_VIA)
                        .where("LOWER(COALESCE(evidence_items.external_reference ->> 'system', '')) <> ?", @consumer.downcase)
                        .where.not(acknowledged_import_sql, @consumer)
    scope = scope.where(evidence_type: @config.exported_kinds)
    scope = scope.where("(evidence_items.updated_at, evidence_items.id) > (?, ?)", @cursor.updated_at, @cursor.id) if @cursor
    scope
  end

  # An item that came in from another system, one that carries a reference to a
  # system that is not a plain link target, and that the consumer has since
  # acknowledged: it lives there already, so it must not travel back. (An import
  # through the exchange itself never gets this far: {NON_HUMAN_VIA} drops it.)
  def acknowledged_import_sql
    link_systems = ExternalReference::LINK_SYSTEMS.map { |system| "'#{system}'" }.join(", ")
    <<~SQL.squish
      (COALESCE(evidence_items.external_reference ->> 'system', '#{ExternalReference::LINK_SYSTEMS.first}') NOT IN (#{link_systems})
       AND EXISTS (
        SELECT 1 FROM feedback_exchange_acks acks
        WHERE acks.tenant_id = evidence_items.tenant_id
          AND acks.evidence_id = evidence_items.id
          AND acks.consumer = ?))
    SQL
  end
end
