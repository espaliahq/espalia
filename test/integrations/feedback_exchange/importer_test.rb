# frozen_string_literal: true

require "test_helper"
require_relative "../../support/feedback_exchange_records"

class FeedbackExchange::ImporterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FeedbackExchangeRecords

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    connect_feedback_exchange(@tenant)
    @handler = PersonDevelopment::CommandHandler.new

    @manager = create(:person, tenant: @tenant, name: "Morgan", email: "morgan@example.com")
    @alex = create(:person, tenant: @tenant, name: "Alex", email: "alex@example.com", manager: @manager)
    @priya = create(:person, tenant: @tenant, name: "Priya", email: "priya@example.com")
    @manager_user = create(:user)
    create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

    @framework_id = SecureRandom.uuid_v7
    @handler.assign_to_framework(@alex.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    @assignment = PersonFrameworkAssignment.find_by!(person_id: @alex.id)
    @importer = FeedbackExchange::Importer.new(@tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def evidence_id = FeedbackExchange::Importer.evidence_id_for(@tenant.id, "chip", "chip-fb-0001")

  def recorded_event
    Rails.configuration.event_store.read.of_type(PersonDevelopment::Events::EvidenceRecorded).to_a
      .find { |event| event.data[:evidence_id] == evidence_id }
  end

  def ledger = FeedbackExchangeImport.find_by!(origin: "chip", external_id: "chip-fb-0001")

  def assert_skipped(reason, record, keeps_record: false)
    result = @importer.import(record)
    assert_equal [ :skipped, reason ], [ result.outcome, result.skip_reason ]
    row = FeedbackExchangeImport.find_by!(external_id: record["id"])
    assert_equal [ "skipped", reason ], [ row.status, row.skip_reason ]
    assert_equal keeps_record, row.record.present?
    assert_equal 0, EvidenceItem.count
  end


  context "a consented record" do
    should "become unplaced evidence on the recipient's assessment, written as its author" do
      result = @importer.import(exchange_record)

      assert_equal :imported, result.outcome
      assert_equal @assignment.id, result.assignment_id
      item = EvidenceItem.find(result.evidence_id)
      assert_equal evidence_id, item.id
      assert_equal @alex.id, item.person_id
      assert_equal @priya.id, item.author_id
      assert_equal "peer", item.source
      assert_equal "peer_feedback", item.evidence_type
      assert_equal "**Great** work on the incident call, *calm and clear*.", item.content
      assert_equal Time.utc(2026, 10, 18, 3, 12, 44), item.recorded_at
      assert EvidenceItem.unplaced.exists?(item.id)
      assert_nil item.cycle_id

      ref = item.external_reference
      assert_equal [ "chip", "chip-fb-0001", "https://chip.example.com/feedback/chip-fb-0001" ],
        [ ref.system, ref.external_id, ref.url ]
      assert_equal({ "kind" => "feedback", "period_name" => "Q4 2026", "given_at" => "2026-10-18T03:12:44Z",
                     "notified" => %w[recipient manager] }, ref.metadata)

      assert_equal "imported", ledger.status
      assert_equal evidence_id, ledger.evidence_id
      assert_nil ledger.record
    end

    should "stamp the event with the exchange, the author and the record as its correlation" do
      @importer.import(exchange_record)

      metadata = recorded_event.metadata
      assert_equal "feedback_exchange", metadata[:acting_via]
      assert_equal @priya.id, metadata[:actor_id]
      assert_equal "chip:chip-fb-0001", metadata[:correlation_id]
      assert_equal @tenant.id, metadata[:tenant_id]
    end

    should "import silently: the system it was given in owns the notifications" do
      perform_enqueued_jobs { @importer.import(exchange_record(given_at: 1.hour.ago.iso8601, notified: [])) }

      assert EvidenceItem.exists?(evidence_id)
      assert_equal 0, Noticed::Notification.count
    end

    should "add nothing on a second run" do
      @importer.import(exchange_record)
      assert_no_difference -> { Rails.configuration.event_store.read.count } do
        assert_equal :unchanged, @importer.import(exchange_record).outcome
      end
      assert_equal 1, EvidenceItem.count
    end

    should "type it by kind when GrowthOS knows the kind, and by the author otherwise" do
      @importer.import(exchange_record(kind: "observation"))
      assert_equal "observation", EvidenceItem.find(evidence_id).evidence_type

      @alex.update!(manager: @priya)
      @importer.import(exchange_record(id: "chip-fb-0002", kind: "kudos"))
      item = EvidenceItem.find(FeedbackExchange::Importer.evidence_id_for(@tenant.id, "chip", "chip-fb-0002"))
      assert_equal [ "manager", "manager_feedback" ], [ item.source, item.evidence_type ]
    end

    should "quote the question it answered above the answer" do
      record = exchange_record(text: "Clear and calm.", text_format: "plain",
        request: { id: "r1", context: "How did the incident call go?", requested_by: { email: "Morgan@example.com" } })
      @importer.import(record)

      item = EvidenceItem.find(evidence_id)
      assert_equal "> How did the incident call go?\n\nClear and calm.", item.content
      assert_equal "morgan@example.com", item.external_reference.metadata["requested_by_email"]
      assert_equal "How did the incident call go?", item.external_reference.metadata["request_context"]
    end

    should "drop a source link that is not http(s)" do
      @importer.import(exchange_record(source_url: "javascript:alert(1)"))
      assert_nil EvidenceItem.find(evidence_id).external_reference.url
    end
  end

  context "the cycle it counts in" do
    setup do
      @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: @alex.id,
             enrolled_at: Time.utc(2026, 10, 1))
    end

    should "be the open cycle when it was given while the recipient was enrolled" do
      @importer.import(exchange_record(given_at: "2026-10-18T03:12:44Z"))
      assert_equal @cycle.cycle_id, EvidenceItem.find(evidence_id).cycle_id
    end

    should "be left for attribution to infer when it was given before" do
      @importer.import(exchange_record(given_at: "2025-06-01T00:00:00Z"))
      item = EvidenceItem.find(evidence_id)
      assert_nil item.cycle_id
      assert_equal Time.utc(2025, 6, 1), item.recorded_at
    end

    should "be left for attribution to infer when it was given after the recipient left the cycle" do
      AssessmentCycleEnrollment.find_by!(person_id: @alex.id).update!(status: "withdrawn", withdrawn_at: Time.utc(2026, 10, 10))
      @importer.import(exchange_record(given_at: "2026-10-18T03:12:44Z"))
      assert_nil EvidenceItem.find(evidence_id).cycle_id
    end
  end

  context "a record seen again" do
    setup { @importer.import(exchange_record) }

    should "update the content as the author when the peer edited it" do
      result = @importer.import(exchange_record(text: "Even *better* now.", updated_at: "2026-10-19T00:00:00Z"))

      assert_equal :updated, result.outcome
      item = EvidenceItem.find(evidence_id)
      assert_equal "Even **better** now.", item.content
      assert_equal @priya.id, item.edited_by_id
      assert_equal "updated", ledger.status
      assert_equal Time.utc(2026, 10, 19), ledger.peer_updated_at
    end

    should "ignore an older or equal version" do
      assert_equal :unchanged, @importer.import(exchange_record(text: "Stale", updated_at: "2026-10-18T03:12:45Z")).outcome
      assert_equal "**Great** work on the incident call, *calm and clear*.", EvidenceItem.find(evidence_id).content
    end

    should "withdraw it as the author when the peer withdrew it" do
      result = @importer.import(exchange_record(status: "withdrawn", updated_at: "2026-10-19T00:00:00Z"))

      assert_equal :withdrawn, result.outcome
      item = EvidenceItem.find(evidence_id)
      assert item.withdrawn?
      assert_equal @priya.id, item.withdrawn_by_id
      assert_equal "Withdrawn in Chip", item.withdrawal_reason
      assert_equal "withdrawn", ledger.status
      assert_equal :withdrawn, @importer.import(exchange_record(status: "withdrawn")).outcome
      assert_equal 1, Rails.configuration.event_store.read.of_type(PersonDevelopment::Events::EvidenceWithdrawn).count
    end

    should "withdraw it as the author when the author narrowed who may read it" do
      result = @importer.import(exchange_record(audience: %w[recipient manager], updated_at: "2026-10-19T00:00:00Z"))

      assert_equal :withdrawn, result.outcome
      item = EvidenceItem.find(evidence_id)
      assert_equal @priya.id, item.withdrawn_by_id
      assert_match(/No longer shared in Chip/, item.withdrawal_reason)
    end

    should "keep a copy withdrawn here, and never acknowledge it" do
      @handler.withdraw_evidence(@alex.id, @framework_id, evidence_id, withdrawn_by_id: @priya.id)
      result = @importer.import(exchange_record(text: "Edited", updated_at: "2026-10-19T00:00:00Z"))

      assert_equal :withdrawn, result.outcome
      assert_not result.lives_here?
      assert EvidenceItem.find(evidence_id).withdrawn?
    end

    should "keep the text it has when the peer's edit is blank" do
      assert_equal :updated, @importer.import(exchange_record(text: "  ", updated_at: "2026-10-19T00:00:00Z")).outcome
      assert_equal "**Great** work on the incident call, *calm and clear*.", EvidenceItem.find(evidence_id).content
    end

    should "log and move on when the domain refuses a withdrawal" do
      @handler.unassign_from_framework(@alex.id, @framework_id, unassigned_by: @manager.id)

      assert_equal :skipped, @importer.withdraw_deleted("chip-fb-0001").outcome
      assert_equal :skipped, @importer.import(exchange_record(status: "withdrawn", updated_at: "2026-10-19T00:00:00Z")).outcome
      assert_not EvidenceItem.find(evidence_id).withdrawn?
    end

    should "withdraw it as the system when the peer deleted it" do
      result = @importer.withdraw_deleted("chip-fb-0001")

      assert_equal :withdrawn, result.outcome
      item = EvidenceItem.find(evidence_id)
      assert item.withdrawn?
      assert_nil item.withdrawn_by_id
      assert_equal "Deleted in Chip", item.withdrawal_reason
      assert_equal "withdrawn", ledger.status
    end

    should "reuse the same item when the ledger row was lost" do
      FeedbackExchangeImport.delete_all
      @importer.import(exchange_record)
      assert_equal 1, EvidenceItem.count
    end
  end

  should "do nothing for a deletion of a record it never saw" do
    assert_equal :unchanged, @importer.withdraw_deleted("never-seen").outcome
    assert_equal 0, FeedbackExchangeImport.count
  end

  should "record a record the peer withdrew before we saw it, without an item" do
    assert_equal :withdrawn, @importer.import(exchange_record(status: "withdrawn")).outcome
    assert_equal 0, EvidenceItem.count
    assert_equal "withdrawn", ledger.status
  end

  context "a record it skips" do
    should "skip an echo of our own feedback" do
      assert_skipped "echo", exchange_record(origin: "growthos")
      assert_skipped "echo", exchange_record(id: "chip-fb-0002", external_reference: { system: "growthos", id: "x" })
    end

    should "skip a record whose audience leaves out anyone who can read it here" do
      assert_skipped "audience_too_narrow", exchange_record(audience: %w[recipient manager])
    end

    should "match the import list against the peer's raw kind, then type it by the author" do
      @tenant.update_feedback_exchange!(settings: { import_kinds: %w[feedback] })
      @importer = FeedbackExchange::Importer.new(Tenant.find(@tenant.id))

      assert_equal :imported, @importer.import(exchange_record(kind: "feedback")).outcome
      assert_equal "peer_feedback", EvidenceItem.find(evidence_id).evidence_type
      skipped = @importer.import(exchange_record(id: "chip-fb-0002", kind: "observation"))
      assert_equal [ :skipped, "kind_not_imported" ], [ skipped.outcome, skipped.skip_reason ]
    end

    should "skip a kind the tenant does not import" do
      connect_feedback_exchange(@tenant, import_kinds: %w[observation])
      @importer = FeedbackExchange::Importer.new(@tenant.reload)
      assert_skipped "kind_not_imported", exchange_record(kind: "feedback")
    end

    should "skip, and keep for a retry, people it cannot find" do
      assert_skipped "author_unmatched", exchange_record(author: { email: "ghost@example.com" }), keeps_record: true
      assert_skipped "recipient_unmatched", exchange_record(id: "chip-fb-0002", recipient: { email: "ghost@example.com" }),
                     keeps_record: true
      assert_equal [ "ghost@example.com" ] * 2, FeedbackExchangeImport.unmatched_people.map { |p| p[:email] }
    end

    should "skip an inactive recipient, ours or the peer's" do
      assert_skipped "recipient_inactive",
        exchange_record(recipient: { email: "alex@example.com", active: false }), keeps_record: true
      @alex.update!(status: "inactive")
      assert_skipped "recipient_inactive", exchange_record(id: "chip-fb-0002"), keeps_record: true
    end

    should "skip an inactive author, ours or the peer's" do
      assert_skipped "author_inactive", exchange_record(author: { email: "priya@example.com", active: false }), keeps_record: true
      @priya.update!(status: "inactive")
      assert_skipped "author_inactive", exchange_record(id: "chip-fb-0002"), keeps_record: true
    end

    should "skip feedback someone gave themselves" do
      assert_skipped "self_feedback", exchange_record(author: { email: "alex@example.com" })
    end

    should "skip a recipient with no assignment, and keep it for a retry" do
      assert_skipped "no_assignment", exchange_record(recipient: { email: "priya@example.com" }, author: { email: "alex@example.com" }),
                     keeps_record: true
      assert_equal @priya.id, ledger.recipient_id
    end

    should "skip a record with no usable id" do
      result = @importer.import(exchange_record(id: nil))
      assert_equal [ :skipped, "invalid_record" ], [ result.outcome, result.skip_reason ]
      assert_equal 0, FeedbackExchangeImport.count
    end

    should "skip a malformed record instead of raising" do
      assert_skipped "invalid_record", exchange_record(author: "priya@example.com")
      assert_skipped "invalid_record", exchange_record(id: "chip-fb-0002", request: "a question")
      assert_skipped "invalid_record", exchange_record(id: "chip-fb-0003", recipient: { email: "alex@example.com", external_ids: "x" })
      assert_skipped "invalid_record", exchange_record(id: "chip-fb-0004", request: { requested_by: "morgan" })
    end

    should "skip a record that does not say when it was given" do
      assert_skipped "invalid_record", exchange_record(given_at: nil)
      assert_skipped "invalid_record", exchange_record(id: "chip-fb-0002", given_at: "last Tuesday")
    end

    should "skip a record that names an origin other than the peer" do
      assert_skipped "invalid_record", exchange_record(origin: "lattice")
    end
  end

  context "retrying" do
    should "carry on past a row that fails, leaving it for the next run" do
      record = exchange_record(recipient: { email: "priya@example.com" }, author: { email: "alex@example.com" })
      @importer.import(record)
      @importer.import(record.merge("id" => "chip-fb-0002"))
      @handler.assign_to_framework(@priya.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      calls = 0
      original = @importer.method(:import)
      flaky = lambda do |r|
        calls += 1
        raise ActiveRecord::StatementInvalid, "boom" if calls == 1

        original.call(r)
      end

      results = @importer.stub(:import, flaky) { @importer.retry_skipped }

      assert_equal %i[imported skipped], results.map(&:outcome).sort
      assert_equal 1, FeedbackExchangeImport.retriable.count
    end

    should "import a skipped record once the recipient is assigned" do
      record = exchange_record(recipient: { email: "priya@example.com" }, author: { email: "alex@example.com" })
      @importer.import(record)
      @handler.assign_to_framework(@priya.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)

      results = @importer.retry_skipped(recipient_id: @priya.id)

      assert_equal [ :imported ], results.map(&:outcome)
      assert_equal @priya.id, EvidenceItem.find(evidence_id).person_id
      assert_nil ledger.record
    end
  end
end
