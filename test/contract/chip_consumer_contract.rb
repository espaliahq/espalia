# frozen_string_literal: true

require "test_helper"
require_relative "../support/pact_contract"
require_relative "../support/feedback_exchange_contract"

# GrowthOS's pact of Chip: our real client, sync job and importer against a
# Pact mock of Chip's feed, in the provider states Chip seeds (Chip's
# contract/README.md). Each test also asserts what the puller does with the
# answer, because those decisions are the contract too.
#
# Not part of `bin/rails test`: `bin/rails contract:consumer` runs it alone
# and copies the pact it writes to contract/pacts/growthos-chip.json.
class FeedbackExchange::ChipConsumerContractTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FeedbackExchangeContract

  BASE_PATH = "/chip/api/feedback-exchange"
  FEED = "#{BASE_PATH}/feedback".freeze
  DELETIONS = "#{BASE_PATH}/feedback/deletions".freeze
  ACK = "#{BASE_PATH}/feedback/ack".freeze

  TENANT_ID = "00000000-0000-7000-8000-00000000e001"
  SAM_ASSIGNMENT_ID = "00000000-0000-7000-8000-00000000e002"

  F001 = "00000000-0000-4000-8000-00000000f001"
  F002 = "00000000-0000-4000-8000-00000000f002"
  F003 = "00000000-0000-4000-8000-00000000f003"
  F004 = "00000000-0000-4000-8000-00000000f004"
  F005 = "00000000-0000-4000-8000-00000000f005"

  CURSORS = {
    priya: "ZjF8MjAyNi0xMC0yMFQyMjowMDowMC4xMjM0NTZafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMQ",
    marcus: "ZjF8MjAyNi0xMC0yMFQyMTowMDowMC4xMTExMTFafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMg",
    lena: "ZjF8MjAyNi0xMC0yMFQyMTozMDowMC4yMjIyMjJafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMw",
    edited: "ZjF8MjAyNi0xMC0yMFQyMzozMDowMC42NTQzMjFafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMQ",
    answered: "ZjF8MjAyNi0xMC0yMFQyMDowMDowMC4zMzMzMzNafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwNA",
    deleted: "ZDF8MjAyNi0xMC0yMFQyMzowMDowMC4wMDAwMDBafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjMwNXwx"
  }.freeze

  PEOPLE = {
    priya: { email: "priya.test@meandu.com", display_name: "Priya Tester", hibob: "3141" },
    sam: { email: "sam.test@meandu.com", display_name: "Sam Recipient", hibob: "2718" },
    marcus: { email: "marcus.test@meandu.com", display_name: "Marcus Tester", hibob: "1618" },
    lena: { email: "lena.test@meandu.com", display_name: "Lena Tester", hibob: "1414" }
  }.freeze

  CONSENTED = %w[recipient management_line hr].freeze

  # Lets the client reach the mock, which listens on loopback. Every other
  # address still goes through the real guard.
  module MockPeerGuard
    def self.check!(url)
      URI(url).host == "127.0.0.1" ? nil : FeedbackExchange::HostGuard.check!(url)
    end
  end

  CONSUMER_PACT_DIR.rmtree if CONSUMER_PACT_DIR.exist?

  setup do
    travel_to Time.at(PACT_TIMESTAMP.to_i).utc
    @url_options = Rails.application.config.action_mailer.default_url_options
    Rails.application.config.action_mailer.default_url_options = { host: "growthos.example", protocol: "https" }

    @tenant = create(:tenant, id: TENANT_ID)
    @tenant.update!(hris_config: HrisConfig.new(provider: "hibob"), feedback_exchange_config: FeedbackExchangeConfig.new(
      peer_name: "chip", base_url: "https://chip.example#{BASE_PATH}", enabled: true
    ))
    @tenant.update_feedback_exchange!(outbound_secret: PACT_SECRET, inbound_secret: "growthos-inbound-#{'0' * 32}")

    ActsAsTenant.with_tenant(@tenant) do
      @marcus = person(:marcus, hibob: nil)
      @priya = person(:priya, manager: @marcus)
      @sam = person(:sam, manager: @marcus)
      @lena = person(:lena, manager: @marcus, hibob: nil)
      person(:jo, manager: @marcus, hibob: nil, email: "jo.test@meandu.com", name: "Jo Recipient")

      PersonDevelopment::CommandHandler.new.assign_to_framework(@sam.id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      PersonFrameworkAssignment.where(person_id: @sam.id).update_all(id: SAM_ASSIGNMENT_ID)
    end

    @pact = PactContract::Consumer.new(consumer: "growthos", provider: "chip", pact_dir: CONSUMER_PACT_DIR)
  end

  teardown do
    Rails.application.config.action_mailer.default_url_options = @url_options
  end

  def person(key, manager: nil, hibob: PEOPLE.dig(key, :hibob), email: PEOPLE.dig(key, :email), name: PEOPLE.dig(key, :display_name))
    create(:person, tenant: @tenant, email: email, name: name, manager: manager,
                    hris_source: hibob && "hibob", external_id: hibob)
  end

  def signed(method, path_with_query, body = "")
    headers = {
      "X-Exchange-Consumer" => "growthos",
      "X-Exchange-Key-Id" => PACT_KEY_ID,
      "X-Exchange-Timestamp" => PACT_TIMESTAMP,
      "X-Exchange-Signature" => FeedbackExchange::Signature.sign(
        secret: PACT_SECRET, method: method, path_with_query: path_with_query, body: body, timestamp: PACT_TIMESTAMP
      )
    }
    body.empty? ? headers : headers.merge("Content-Type" => "application/json")
  end

  def json_response = { "Content-Type" => PactContract.term("^application/json(;.*)?$", "application/json; charset=utf-8") }

  def protocol_person(key)
    person = PEOPLE.fetch(key)
    { email: person[:email], display_name: PactContract.like(person[:display_name]), active: true, external_ids: { hibob: person[:hibob] } }
  end

  def chip_record(id:, author:, given_at:, text:, updated_at: given_at, audience: CONSENTED, request: nil, period: nil)
    {
      id: id, origin: "chip", status: "active", given_at: given_at, updated_at: updated_at,
      kind: "feedback", text: PactContract.like(text), text_format: "markdown",
      author: protocol_person(author), recipient: protocol_person(:sam),
      request: request, period: period, audience: audience,
      notified: PactContract.each_like(PactContract.term("^(author|recipient|manager)$", "author")),
      source_url: PactContract.term("^https://\\S+/dashboard/feedback/[0-9a-f-]{36}$", "https://chip.example/chip/dashboard/feedback/#{id}"),
      external_reference: nil
    }
  end

  # The record as the mock serves it: every matcher replaced by its example.
  def served(record) = strip_matchers(JSON.parse(record.to_json))

  def strip_matchers(value)
    case value
    when Hash then value.key?("pact:matcher:type") ? strip_matchers(value["value"]) : value.transform_values { |v| strip_matchers(v) }
    when Array then value.map { |v| strip_matchers(v) }
    else value
    end
  end

  def expect_feed(state, description, items: [], next_cursor: nil)
    @pact.upon_receiving(description, given: state) do |i|
      i.request "GET", FEED, query: { limit: "100" }, headers: signed("GET", "#{FEED}?limit=100")
      i.response 200, headers: json_response, body: { items: items, next_cursor: next_cursor, has_more: false }
    end
  end

  def expect_deletions(state, description, items: [], next_cursor: nil)
    @pact.upon_receiving(description, given: state) do |i|
      i.request "GET", DELETIONS, query: { limit: "100" }, headers: signed("GET", "#{DELETIONS}?limit=100")
      i.response 200, headers: json_response, body: { items: items, next_cursor: next_cursor, has_more: false }
    end
  end

  def expect_ack(state, description, chip_id)
    body = JSON.generate(items: [ { id: chip_id, remote_id: evidence_id(chip_id), remote_url: "https://growthos.example/assessments/#{SAM_ASSIGNMENT_ID}" } ])
    @pact.upon_receiving(description, given: state) do |i|
      i.request "POST", ACK, headers: signed("POST", ACK, body), body: body
      i.response 204
    end
  end

  def client(base_url, secret: PACT_SECRET)
    FeedbackExchange::Client.new(base_url: "#{base_url}#{BASE_PATH}", outbound_secret: secret, host_guard: MockPeerGuard)
  end

  def sync(secret: PACT_SECRET)
    @pact.run { |base_url| FeedbackExchange::SyncJob.perform_now(@tenant, client: client(base_url, secret: secret)) }
  end

  def evidence_id(chip_id) = FeedbackExchange::Importer.evidence_id_for(TENANT_ID, "chip", chip_id)
  def item(chip_id) = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find_by(id: evidence_id(chip_id)) }
  def config = @tenant.reload.feedback_exchange_config

  def import_directly(record)
    ActsAsTenant.with_tenant(@tenant) { FeedbackExchange::Importer.new(@tenant).import(served(record)) }
  end

  PRIYA_GIVEN_AT = "2026-10-20T22:00:00.123456Z"
  PRIYA_TEXT = "Thanks for running the **database cutover** so calmly."

  def priya_record(**overrides) = chip_record(id: F001, author: :priya, given_at: PRIYA_GIVEN_AT, text: PRIYA_TEXT, **overrides)

  context "the exchange is disabled" do
    should "stop the run on Chip's 404, with no retry and nothing stored" do
      state = "the exchange is disabled"
      @pact.upon_receiving("a request for Chip's feed while Chip has the exchange switched off", given: state) do |i|
        i.request "GET", FEED, query: { limit: "100" }, headers: signed("GET", "#{FEED}?limit=100")
        i.response 404
      end

      assert_no_enqueued_jobs(only: FeedbackExchange::SyncJob) { sync }

      assert_nil config.cursor
      assert_nil config.last_synced_at
    end
  end

  context "no feedback is waiting" do
    setup { @state = "no feedback is waiting" }

    should "read both feeds, import nothing and keep its cursors" do
      expect_feed(@state, "a request for Chip's first feed page when nothing is waiting")
      expect_deletions(@state, "a request for Chip's first deletions page when nothing is waiting")

      sync

      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { EvidenceItem.count }
      assert_equal [ nil, nil ], [ config.cursor, config.deletions_cursor ]
      assert_not_nil config.last_synced_at
    end

    should "stop, without a retry, when Chip refuses our signature" do
      wrong = "not-the-pact-secret-0123456789abcdef0123456789"
      @pact.upon_receiving("a request signed with a secret Chip doesn't hold", given: @state) do |i|
        headers = signed("GET", "#{FEED}?limit=100").merge(
          "X-Exchange-Key-Id" => FeedbackExchange::Signature.key_id(wrong),
          "X-Exchange-Signature" => FeedbackExchange::Signature.sign(secret: wrong, method: "GET", path_with_query: "#{FEED}?limit=100",
                                                                     body: "", timestamp: PACT_TIMESTAMP)
        )
        i.request "GET", FEED, query: { limit: "100" }, headers: headers
        i.response 401
      end

      assert_no_enqueued_jobs(only: FeedbackExchange::SyncJob) { sync(secret: wrong) }

      assert_nil config.last_synced_at
    end
  end

  context "priya.test has given sam.test consented feedback" do
    setup { @state = "priya.test has given sam.test consented feedback" }

    should "import it as unplaced peer feedback to sam, acknowledge it and move the cursor" do
      expect_feed(@state, "a request for Chip's feed with priya.test's consented feedback to sam.test",
                  items: [ priya_record ], next_cursor: CURSORS[:priya])
      expect_ack(@state, "GrowthOS's ack after importing priya.test's feedback to sam.test", F001)
      expect_deletions(@state, "a request for Chip's deletions page while priya.test's feedback waits")

      sync

      imported = item(F001)
      assert_equal [ @sam.id, @priya.id ], [ imported.person_id, imported.author_id ]
      assert_equal [ "peer", "peer_feedback" ], [ imported.source, imported.evidence_type ]
      assert_nil imported.capability_stable_id, "imported feedback waits unplaced"
      assert_equal PRIYA_TEXT, imported.content
      assert_equal Time.iso8601(PRIYA_GIVEN_AT), imported.recorded_at
      assert_equal CURSORS[:priya], config.cursor
    end
  end

  context "marcus.test has given sam.test consented feedback" do
    should "import it as manager feedback, since marcus manages sam" do
      state = "marcus.test has given sam.test consented feedback"
      record = chip_record(id: F002, author: :marcus, given_at: "2026-10-20T21:00:00.111111Z", text: "Great job leading the incident review this week.")
      expect_feed(state, "a request for Chip's feed with marcus.test's consented feedback to sam.test", items: [ record ], next_cursor: CURSORS[:marcus])
      expect_ack(state, "GrowthOS's ack after importing marcus.test's feedback to sam.test", F002)
      expect_deletions(state, "a request for Chip's deletions page while marcus.test's feedback waits")

      sync

      assert_equal [ @marcus.id, "manager", "manager_feedback" ], item(F002).then { |i| [ i.author_id, i.source, i.evidence_type ] }
      assert_equal CURSORS[:marcus], config.cursor
    end
  end

  context "lena.test has given sam.test feedback without manager consent" do
    should "skip it as shared too narrowly, send no ack and still move the cursor" do
      state = "lena.test has given sam.test feedback without manager consent"
      record = chip_record(id: F003, author: :lena, given_at: "2026-10-20T21:30:00.222222Z",
                           text: "Your review of my pull request was thoughtful and quick.", audience: %w[recipient hr])
      expect_feed(state, "a request for Chip's feed with lena.test's feedback to sam.test, shared without manager consent",
                  items: [ record ], next_cursor: CURSORS[:lena])
      expect_deletions(state, "a request for Chip's deletions page while lena.test's feedback waits")

      sync

      assert_nil item(F003)
      ledger = ActsAsTenant.with_tenant(@tenant) { FeedbackExchangeImport.find_by!(external_id: F003) }
      assert_equal [ "skipped", "audience_too_narrow" ], [ ledger.status, ledger.skip_reason ]
      assert_equal CURSORS[:lena], config.cursor
    end
  end

  context "priya.test's feedback to sam.test was edited" do
    should "update the copy imported before and acknowledge it again" do
      state = "priya.test's feedback to sam.test was edited"
      import_directly(priya_record)
      edited_text = "Thanks for running the **database cutover** so calmly, and for the rollback plan."
      edited = priya_record(text: edited_text, updated_at: "2026-10-20T23:30:00.654321Z")
      expect_feed(state, "a request for Chip's feed with the edited feedback", items: [ edited ], next_cursor: CURSORS[:edited])
      expect_ack(state, "GrowthOS's ack after updating priya.test's edited feedback", F001)
      expect_deletions(state, "a request for Chip's deletions page after priya.test's edit")

      sync

      assert_equal edited_text, item(F001).content
      ledger = ActsAsTenant.with_tenant(@tenant) { FeedbackExchangeImport.find_by!(external_id: F001) }
      assert_equal "updated", ledger.status
    end
  end

  context "priya.test has answered sam.test's request in a period" do
    should "carry the request's question, who asked and the period" do
      state = "priya.test has answered sam.test's request in a period"
      context_text = "Could you share how I handled the **database cutover**? A concrete example helps most."
      record = chip_record(
        id: F004, author: :priya, given_at: "2026-10-20T20:00:00.333333Z",
        text: "During the cutover Sam **wrote the rollback plan** and rehearsed it twice.",
        request: { id: "00000000-0000-4000-8000-00000000f204", context: PactContract.like(context_text), requested_by: protocol_person(:sam) },
        period: { id: "00000000-0000-4000-8000-00000000f104", name: "Q4 2026" }
      )
      expect_feed(state, "a request for Chip's feed with priya.test's answer to sam.test's request", items: [ record ], next_cursor: CURSORS[:answered])
      expect_ack(state, "GrowthOS's ack after importing priya.test's answer", F004)
      expect_deletions(state, "a request for Chip's deletions page while priya.test's answer waits")

      sync

      imported = item(F004)
      metadata = imported.external_reference.metadata
      assert_equal [ context_text, "sam.test@meandu.com", "Q4 2026" ], metadata.values_at("request_context", "requested_by_email", "period_name")
      assert imported.content.start_with?("> Could you share how I handled"), "the question is quoted above the answer"
    end
  end

  context "priya.test's feedback to sam.test was deleted" do
    should "withdraw the copy imported before and store the deletions cursor" do
      state = "priya.test's feedback to sam.test was deleted"
      import_directly(chip_record(id: F005, author: :priya, given_at: "2026-10-20T19:00:00.000000Z", text: "Since deleted in Chip."))
      expect_feed(state, "a request for Chip's feed after priya.test's feedback was deleted")
      expect_deletions(state, "a request for Chip's deletions feed after P&C deleted priya.test's feedback",
                       items: [ { id: F005, deleted_at: PactContract.term("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}Z$", "2026-10-20T23:00:00.000000Z") } ],
                       next_cursor: CURSORS[:deleted])

      sync

      assert_equal "withdrawn", item(F005).link_status
      assert_equal CURSORS[:deleted], config.deletions_cursor
    end
  end

  context "priya.test's feedback to sam.test can be acknowledged" do
    should "send the ack exactly as the sync job builds it" do
      state = "priya.test's feedback to sam.test can be acknowledged"
      expect_ack(state, "GrowthOS's ack naming where priya.test's feedback to sam.test lives here", F001)

      answer = @pact.run do |base_url|
        client(base_url).ack([ { id: F001, remote_id: evidence_id(F001), remote_url: "https://growthos.example/assessments/#{SAM_ASSIGNMENT_ID}" } ])
      end

      assert_nil answer, "a 204 carries nothing back"
    end
  end
end
