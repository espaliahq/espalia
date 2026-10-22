# frozen_string_literal: true

require "test_helper"
require_relative "../../support/feedback_exchange_records"

class FeedbackExchange::SyncJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FeedbackExchangeRecords

  BASE = "https://chip.example.com/api/feedback-exchange"

  setup do
    @tenant = create(:tenant)
    connect_feedback_exchange(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @alex = create(:person, tenant: @tenant, name: "Alex", email: "alex@example.com")
      @priya = create(:person, tenant: @tenant, name: "Priya", email: "priya@example.com")
      @framework_id = SecureRandom.uuid_v7
      PersonDevelopment::CommandHandler.new.assign_to_framework(@alex.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      @assignment_id = PersonFrameworkAssignment.find_by!(person_id: @alex.id).id
    end

    @stubs = Faraday::Adapter::Test::Stubs.new
    @feed = {}
    @deletions = { nil => { items: [], next_cursor: nil, has_more: false } }
    @acks = []
    @ack_status = 204
    @feed_status = 200
    @stubs.get("/api/feedback-exchange/feedback") do |env|
      @feed_status == 200 ? json(@feed.fetch(env.params["since"])) : [ @feed_status, {}, "" ]
    end
    @stubs.get("/api/feedback-exchange/feedback/deletions") { |env| json(@deletions.fetch(env.params["since"])) }
    @stubs.post("/api/feedback-exchange/feedback/ack") do |env|
      @acks << JSON.parse(env.request_body)["items"] if @ack_status == 204
      [ @ack_status, {}, "" ]
    end
  end

  def json(body) = [ 200, { "Content-Type" => "application/json" }, body.to_json ]

  def client
    connection = Faraday.new(url: "#{BASE}/") { |f| f.adapter :test, @stubs }
    FeedbackExchange::Client.new(base_url: BASE, outbound_secret: "o" * 64, connection: connection)
  end

  def run_sync = FeedbackExchange::SyncJob.perform_now(@tenant, client: client)
  def config = @tenant.reload.feedback_exchange_config
  def evidence_id(id) = FeedbackExchange::Importer.evidence_id_for(@tenant.id, "chip", id)

  should "import each page, acknowledge it, then move the cursor" do
    @feed[nil] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: true }
    @feed["c1"] = { items: [ exchange_record(id: "b"), exchange_record(id: "c", audience: %w[recipient]) ],
                    next_cursor: "c2", has_more: false }

    run_sync

    ActsAsTenant.with_tenant(@tenant) { assert_equal 2, EvidenceItem.count }
    assert_equal [
      [ { "id" => "a", "remote_id" => evidence_id("a"), "remote_url" => "http://example.com/assessments/#{@assignment_id}" } ],
      [ { "id" => "b", "remote_id" => evidence_id("b"), "remote_url" => "http://example.com/assessments/#{@assignment_id}" } ]
    ], @acks
    assert_equal "c2", config.cursor
    assert_not_nil config.last_synced_at
  end

  should "fail rather than fetch the same page again when the peer does not move its cursor" do
    @feed[nil] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: true }
    @feed["c1"] = { items: [], next_cursor: "c1", has_more: true }

    error = assert_raises(FeedbackExchange::Errors::ApiError) { FeedbackExchange::SyncJob.new.perform(@tenant, client: client) }
    assert_match(/did not move its cursor/, error.message)
    assert_equal "c1", config.cursor
  end

  context "when the peer has the exchange switched off" do
    setup { @feed_status = 404 }

    should "stop the run without a retry, leaving the cursor and the sync time alone" do
      @tenant.update_feedback_exchange!(settings: { cursor: "c0" })

      assert_no_enqueued_jobs(only: FeedbackExchange::SyncJob) { run_sync }

      assert_equal "c0", config.cursor
      assert_nil config.last_synced_at
      assert_empty @acks
    end
  end

  should "log a 409 to an ack and carry on without a retry" do
    @ack_status = 409
    @feed[nil] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: false }

    assert_no_enqueued_jobs(only: FeedbackExchange::SyncJob) { run_sync }

    assert_equal "c1", config.cursor
    assert_not_nil config.last_synced_at
    ActsAsTenant.with_tenant(@tenant) { assert_equal 1, EvidenceItem.count }
  end

  should "add nothing when run again" do
    @feed[nil] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: false }
    @feed["c1"] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: false }
    run_sync
    run_sync
    ActsAsTenant.with_tenant(@tenant) { assert_equal 1, EvidenceItem.count }
  end

  should "leave the cursor where it was when the acknowledgement fails" do
    @feed[nil] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: false }
    @ack_status = 503

    assert_raises(FeedbackExchange::Errors::ApiError) { FeedbackExchange::SyncJob.new.perform(@tenant, client: client) }
    assert_nil config.cursor

    @ack_status = 204
    run_sync
    assert_equal "c1", config.cursor
    ActsAsTenant.with_tenant(@tenant) { assert_equal 1, EvidenceItem.count }
  end

  should "withdraw what the peer deleted and move the deletions cursor" do
    @feed[nil] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: false }
    @feed["c1"] = { items: [], next_cursor: "c1", has_more: false }
    run_sync
    @deletions["d0"] = { items: [ { id: "a", deleted_at: "2026-10-19T00:00:00Z" } ], next_cursor: "d1", has_more: false }
    @tenant.update_feedback_exchange!(settings: { deletions_cursor: "d0" })

    run_sync

    ActsAsTenant.with_tenant(@tenant) { assert EvidenceItem.find(evidence_id("a")).withdrawn? }
    assert_equal "d1", config.deletions_cursor
  end

  should "retry skipped records before pulling" do
    @feed[nil] = { items: [ exchange_record(id: "a", recipient: { email: "priya@example.com" }, author: { email: "alex@example.com" }) ],
                   next_cursor: "c1", has_more: false }
    @feed["c1"] = { items: [], next_cursor: "c1", has_more: false }
    run_sync
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal 0, EvidenceItem.count
      PersonDevelopment::CommandHandler.new.assign_to_framework(@priya.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    end

    run_sync

    ActsAsTenant.with_tenant(@tenant) { assert_equal @priya.id, EvidenceItem.find(evidence_id("a")).person_id }
    assert_equal "a", @acks.last.sole["id"]
  end

  should "do nothing while the exchange is switched off" do
    @feed[nil] = { items: [ exchange_record(id: "a") ], next_cursor: "c1", has_more: false }
    @tenant.update_feedback_exchange!(settings: { enabled: false })
    run_sync
    ActsAsTenant.with_tenant(@tenant) { assert_equal 0, FeedbackExchangeImport.count }
    assert_nil config.last_synced_at
  end

  should "discard a run the peer rejects, keeping the cursor" do
    @feed_status = 401
    assert_nothing_raised { run_sync }
    assert_nil config.cursor
  end

  context "SyncAllTenantsJob" do
    should "enqueue a sync for each tenant whose exchange is set up" do
      create(:tenant)
      disabled = create(:tenant)
      connect_feedback_exchange(disabled, enabled: false)

      FeedbackExchange::SyncAllTenantsJob.perform_now

      assert_enqueued_jobs 1, only: FeedbackExchange::SyncJob
      assert_enqueued_with(job: FeedbackExchange::SyncJob, args: [ @tenant ])
    end
  end

  context "AssignmentRetry" do
    should "sync when a newly assigned person has feedback waiting for an assignment" do
      ActsAsTenant.with_tenant(@tenant) do
        FeedbackExchange::Importer.new(@tenant).import(
          exchange_record(id: "a", recipient: { email: "priya@example.com" }, author: { email: "alex@example.com" })
        )
        assert_enqueued_with(job: FeedbackExchange::SyncJob, args: [ @tenant ]) do
          PersonDevelopment::CommandHandler.new.assign_to_framework(@priya.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
        end
      end
    end

    should "not sync for an assignment nothing waits on" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_no_enqueued_jobs(only: FeedbackExchange::SyncJob) do
          PersonDevelopment::CommandHandler.new.assign_to_framework(@priya.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
        end
      end
    end
  end
end
