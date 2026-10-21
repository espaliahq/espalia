# frozen_string_literal: true

# Turns one protocol record (§4) from a peer into GrowthOS feedback, or says
# why not, and writes the outcome to the ledger ({FeedbackExchangeImport}).
#
# A new record becomes UNPLACED evidence on the recipient's assessment, written
# as its real author: `PersonDevelopment::CommandHandler#record_evidence`
# directly (the author may have no account, so the Operations' signed-in
# person does not fit), inside `acting_via: :feedback_exchange`. Its evidence
# id is a UUIDv5 of (tenant, origin, id), so a replay or a lost ledger row
# reproduces the same item instead of a second one.
#
# A record seen again with a newer `updated_at` updates the item's content as
# the author; `status: withdrawn` withdraws it as the author. A deletions-feed
# id withdraws it as the system ({#withdraw_deleted}).
#
# Outcomes: :imported, :updated, :withdrawn, :unchanged (seen before, nothing
# new) or :skipped with a reason from {FeedbackExchangeImport::SKIP_REASONS}.
#
# @example
#   result = FeedbackExchange::Importer.new(tenant).import(record)
#   result.outcome # => :imported
class FeedbackExchange::Importer
  # Frozen forever: every imported item's id is derived from it.
  NAMESPACE = "27186816-29e3-43ba-b58b-35dd84bf53ed"

  # Who can read feedback in GrowthOS, in protocol roles (§4.1). A record is
  # imported only when its author agreed to every one of them (§2.1).
  VISIBILITY = %w[recipient management_line hr].freeze

  # Our own system name: a record from it, or copied from it, is an echo (§2.5).
  SELF = FeedbackExchange::Client::CONSUMER


  # What the domain raises when it refuses a command: CommandError, or the
  # bare RuntimeError of an invariant such as "not yet assigned".
  REFUSALS = [ PersonDevelopment::Aggregate::CommandError, RuntimeError ].freeze

  Result = Data.define(:outcome, :skip_reason, :evidence_id, :assignment_id) do
    # @return [Boolean] whether the record now lives here as an active item
    def lives_here? = %i[imported updated unchanged].include?(outcome) && evidence_id.present?
  end

  # @param tenant [Tenant]
  # @param command_handler [PersonDevelopment::CommandHandler]
  def initialize(tenant, command_handler: PersonDevelopment::CommandHandler.new)
    @tenant = tenant
    @config = tenant.feedback_exchange_config
    @matcher = FeedbackExchange::PersonMatcher.new(tenant)
    @command_handler = command_handler
  end

  # The id an imported record's evidence item carries.
  #
  # @param tenant_id [String]
  # @param origin [String]
  # @param external_id [String]
  # @return [String]
  def self.evidence_id_for(tenant_id, origin, external_id)
    Digest::UUID.uuid_v5(NAMESPACE, "#{tenant_id}:#{origin}:#{external_id}")
  end

  # @param record [Hash] a protocol record, string keys
  # @return [Result]
  def import(record)
    record = record.to_h.deep_stringify_keys
    return invalid(record) unless keyed?(record)

    ledger = FeedbackExchangeImport.find_or_initialize_by(origin: record["origin"], external_id: record["id"].to_s)
    item = EvidenceItem.find_by(id: self.class.evidence_id_for(@tenant.id, record["origin"], record["id"]))
    item ? revisit(ledger, item, record) : first_sight(ledger, record)
  end

  # Withdraws the copy of a record the peer hard-deleted (protocol §5.2).
  #
  # @param external_id [String]
  # @param origin [String]
  # @return [Result]
  def withdraw_deleted(external_id, origin: @config.peer_name)
    ledger = FeedbackExchangeImport.find_or_initialize_by(origin: origin, external_id: external_id.to_s)
    item = EvidenceItem.find_by(id: self.class.evidence_id_for(@tenant.id, origin, external_id))
    if item && !item.withdrawn?
      refused = refused(origin, external_id) do
        dispatch(origin, external_id, actor_id: nil) do
          @command_handler.withdraw_evidence(item.person_id, item.framework_id, item.id,
            withdrawn_by_id: nil, reason: "Deleted in #{peer_label(origin)}")
        end
      end
      return refused if refused
    end
    return result(:unchanged) if ledger.new_record? && item.nil?

    write(ledger, status: "withdrawn", evidence_id: item&.id, record: nil)
    result(:withdrawn, evidence_id: item&.id)
  end

  # Imports again every record skipped for a reason our side can fix,
  # optionally only those for one recipient.
  #
  # @param recipient_id [String, nil]
  # @return [Array<Result>]
  def retry_skipped(recipient_id: nil)
    scope = FeedbackExchangeImport.retriable
    scope = scope.where(recipient_id: recipient_id) if recipient_id
    scope.find_each.map { |ledger| import(ledger.record) }
  end

  private

  # ── A record we have already turned into an item ──

  # A withdrawn copy stays withdrawn and is never acknowledged as living here.
  def revisit(ledger, item, record)
    if item.withdrawn?
      write(ledger, status: "withdrawn", evidence_id: item.id, record: nil) unless ledger.status == "withdrawn"
      return result(:withdrawn, evidence_id: item.id)
    end
    return withdraw_by_author(ledger, item, record, "Withdrawn in #{peer_label(record['origin'])}") if record["status"] == "withdrawn"
    unless newer?(record, ledger)
      return result(:unchanged, evidence_id: item.id, assignment_id: assignment_id_for(item))
    end
    # Consent is data (§2.1): an author who narrows it takes the copy back.
    if narrower_than_visibility?(record)
      return withdraw_by_author(ledger, item, record,
        "No longer shared in #{peer_label(record['origin'])} with everyone who can read it here")
    end

    update_content(item, record) { |refusal| return refusal }
    write(ledger, status: "updated", evidence_id: item.id, record: nil, peer_updated_at: peer_updated_at(record))
    result(:updated, evidence_id: item.id, assignment_id: assignment_id_for(item))
  end

  # A blank edit keeps the text we have rather than failing the update.
  def update_content(item, record)
    content = content_for(record)
    return if content.strip.empty? || content == item.content

    refusal = refused(record["origin"], record["id"]) do
      dispatch(record["origin"], record["id"], actor_id: item.author_id) do
        @command_handler.update_evidence(item.person_id, item.framework_id, item.id,
          title: item.title, content: content, evidence_type: item.evidence_type,
          custom_type_label: item.custom_type_label, external_reference: item.external_reference.as_json,
          edited_by_id: item.author_id)
      end
    end
    yield refusal if refusal
  end

  def withdraw_by_author(ledger, item, record, reason)
    refusal = refused(record["origin"], record["id"]) do
      dispatch(record["origin"], record["id"], actor_id: item.author_id) do
        @command_handler.withdraw_evidence(item.person_id, item.framework_id, item.id,
          withdrawn_by_id: item.author_id, reason: reason)
      end
    end
    return refusal if refusal

    write(ledger, status: "withdrawn", evidence_id: item.id, record: nil, peer_updated_at: peer_updated_at(record))
    result(:withdrawn, evidence_id: item.id)
  end

  # Runs a write the domain may refuse (the recipient was unassigned since,
  # say). A refusal is logged and leaves the ledger as it was; it must not
  # stop the rest of the page, or the run would fail on it forever.
  #
  # @return [Result, nil] a skipped result when refused
  def refused(origin, external_id)
    yield
    nil
  rescue *REFUSALS => e
    Rails.logger.warn("[FeedbackExchange] #{origin}:#{external_id} refused: #{e.message}")
    result(:skipped, skip_reason: "invalid_record")
  end

  def newer?(record, ledger)
    updated = peer_updated_at(record)
    updated.present? && (ledger.peer_updated_at.nil? || updated > ledger.peer_updated_at)
  end

  # ── A record we have not imported ──

  def first_sight(ledger, record)
    if record["status"] == "withdrawn"
      write(ledger, status: "withdrawn", record: nil, peer_updated_at: peer_updated_at(record))
      return result(:withdrawn)
    end

    reason, author, recipient, assignment = assess(record)
    return skip(ledger, record, reason, recipient: recipient) if reason

    item = record!(record, author, recipient, assignment)
    write(ledger, status: "imported", evidence_id: item.id, recipient_id: recipient.id, record: nil,
                  peer_updated_at: peer_updated_at(record))
    result(:imported, evidence_id: item.id, assignment_id: assignment.id)
  rescue *REFUSALS => e
    # Another run imported it first; that item is the answer, not a refusal.
    raced = EvidenceItem.find_by(id: self.class.evidence_id_for(@tenant.id, record["origin"], record["id"]))
    return result(:unchanged, evidence_id: raced.id, assignment_id: assignment_id_for(raced)) if raced

    Rails.logger.warn("[FeedbackExchange] #{record['origin']}:#{record['id']} refused: #{e.message}")
    skip(ledger, record, "invalid_record")
  end

  # The first reason not to import, in the order a reader would check: the
  # record itself, then the people it names.
  #
  # @return [Array] [skip_reason or nil, author, recipient, assignment]
  def assess(record)
    return [ "echo" ] if echo?(record)
    return [ "audience_too_narrow" ] if narrower_than_visibility?(record)
    return [ "kind_not_imported" ] unless kind_imported?(record["kind"])

    author = @matcher.match(record["author"])
    return [ "author_unmatched" ] if author.nil?
    return [ "author_inactive" ] if author.status != "active" || record.dig("author", "active") == false

    recipient = @matcher.match(record["recipient"])
    return [ "recipient_unmatched" ] if recipient.nil?
    return [ "recipient_inactive", author, recipient ] if recipient.status != "active" || record.dig("recipient", "active") == false
    return [ "self_feedback", author, recipient ] if author.id == recipient.id

    assignment = PersonFrameworkAssignment.where(person_id: recipient.id).order(:created_at).first
    return [ "no_assignment", author, recipient ] if assignment.nil?

    [ nil, author, recipient, assignment ]
  end

  # Records come only from the configured peer, keyed on (origin, id); one that
  # names another origin could never be found again by the deletions feed.
  def keyed?(record)
    [ @config.peer_name, SELF ].include?(record["origin"].presence) && record["id"].to_s.present? && well_shaped?(record)
  end

  # Every nested part the importer digs into is an object, or absent where the
  # protocol allows it, so a malformed record is skipped instead of raising.
  # `given_at` is required: it dates the item and decides its cycle.
  def well_shaped?(record)
    people = record.values_at("author", "recipient")
    parse_time(record["given_at"]).present? &&
      people.all?(Hash) &&
      people.all? { |person| person["external_ids"].nil? || person["external_ids"].is_a?(Hash) } &&
      record.values_at("request", "period", "external_reference").all? { |part| part.nil? || part.is_a?(Hash) } &&
      (record.dig("request", "requested_by").nil? || record.dig("request", "requested_by").is_a?(Hash))
  end

  def narrower_than_visibility?(record)
    !(VISIBILITY - Array(record["audience"]).map(&:to_s)).empty?
  end

  def echo?(record)
    record["origin"] == SELF || record.dig("external_reference", "system") == SELF
  end

  def kind_imported?(kind)
    kinds = Array(@config.import_kinds).compact_blank
    kinds.empty? || kinds.include?(kind.to_s)
  end

  def record!(record, author, recipient, assignment)
    source = EvidenceItem.source_for(author: author, recipient: recipient)
    given_at = parse_time(record["given_at"])
    evidence_id = self.class.evidence_id_for(@tenant.id, record["origin"], record["id"])

    dispatch(record["origin"], record["id"], actor_id: author.id) do
      @command_handler.record_evidence(recipient.id, assignment.framework_id, evidence_id,
        source: source,
        evidence_type: evidence_type_for(record["kind"], source),
        content: content_for(record),
        author_id: author.id,
        external_reference: external_reference_for(record),
        cycle_id: cycle_id_for(recipient, assignment, given_at),
        recorded_at: given_at)
    end
    EvidenceItem.find(evidence_id)
  end

  # A kind GrowthOS knows keeps its type; anything else is feedback from a
  # manager or a peer, whichever the author is.
  def evidence_type_for(kind, source)
    return kind if EvidenceItem::EVIDENCE_TYPES.include?(kind) && kind != "other"

    source == "manager" ? "manager_feedback" : "peer_feedback"
  end

  # The text in Markdown, with the question it answered quoted above it when it
  # was asked for, so the answer reads in context.
  def content_for(record)
    body = FeedbackExchange::TextFormat.to_markdown(record["text"], format: record["text_format"])
    context = record.dig("request", "context").to_s.strip
    return body if context.empty?

    quoted = FeedbackExchange::TextFormat.to_markdown(context, format: record["text_format"])
      .lines(chomp: true).map { |line| "> #{line}".rstrip }.join("\n")
    "#{quoted}\n\n#{body}"
  end

  def external_reference_for(record)
    {
      system: record["origin"],
      external_id: record["id"].to_s,
      url: safe_url(record["source_url"]),
      metadata: {
        kind: record["kind"],
        request_context: record.dig("request", "context"),
        requested_by_email: record.dig("request", "requested_by", "email")&.downcase,
        period_name: record.dig("period", "name"),
        given_at: record["given_at"],
        notified: Array(record["notified"]).map(&:to_s)
      }.compact
    }
  end

  def safe_url(url)
    ExternalReference.new(url: url).safe_url
  end

  # The open cycle claims the item only when it was given while the recipient
  # was enrolled in it; anything older is left for attribution to infer, so a
  # backfill of last year's feedback never counts as this cycle's.
  def cycle_id_for(recipient, assignment, given_at)
    return nil if given_at.nil?

    cycle = AssessmentCycle.open_cycles.for_framework(assignment.framework_id).first
    return nil if cycle.nil?

    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: cycle.cycle_id, person_id: recipient.id)
    return nil if enrollment.nil? || given_at < enrollment.enrolled_at
    return nil if enrollment.withdrawn_at && given_at > enrollment.withdrawn_at

    cycle.cycle_id
  end

  # ── Writing ──

  def dispatch(origin, external_id, actor_id:, &block)
    AuditMetadata.with(acting_via: :feedback_exchange, actor_id: actor_id, correlation_id: "#{origin}:#{external_id}") do
      AuditMetadata.wrap_event_store do
        Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id, &block)
      end
    end
  end

  def skip(ledger, record, reason, recipient: nil)
    retriable = FeedbackExchangeImport::RETRIABLE_REASONS.include?(reason)
    write(ledger, status: "skipped", skip_reason: reason, recipient_id: recipient&.id,
                  record: retriable ? record : nil, peer_updated_at: peer_updated_at(record))
    result(:skipped, skip_reason: reason)
  end

  def invalid(record)
    origin = record["origin"].to_s.presence
    external_id = record["id"].to_s.presence
    Rails.logger.warn("[FeedbackExchange] Skipped a record not keyed by the peer: #{origin.inspect} #{external_id.inspect}")
    return result(:skipped, skip_reason: "invalid_record") unless origin && external_id

    skip(FeedbackExchangeImport.find_or_initialize_by(origin: origin, external_id: external_id), record, "invalid_record")
  end

  def write(ledger, status:, skip_reason: nil, **attributes)
    ledger.update!(status: status, skip_reason: skip_reason, synced_at: Time.current, **attributes)
  end

  def result(outcome, skip_reason: nil, evidence_id: nil, assignment_id: nil)
    Result.new(outcome:, skip_reason:, evidence_id:, assignment_id:)
  end

  def assignment_id_for(item)
    PersonFrameworkAssignment.where(person_id: item.person_id, framework_id: item.framework_id).pick(:id)
  end

  def peer_updated_at(record)
    parse_time(record["updated_at"])
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def peer_label(origin)
    Reporting::OriginLabels.peer_label(origin)
  end
end
