# frozen_string_literal: true

require "test_helper"
require "capybara"
require_relative "../support/pact_contract"
require_relative "../support/feedback_exchange_contract"

# Chip's pact of GrowthOS, replayed against our real app: Puma in-process, as
# system tests boot it, with the clock frozen where Chip signed every request
# and no request filter, so our real verifier checks Chip's real signatures.
#
# The pact comes from CHIP_PACT_FILE (a pact, or a whole /contract response);
# `bin/rails contract:provider` sets it. Not part of `bin/rails test`.
class FeedbackExchange::ChipProviderContractTest < ActiveSupport::TestCase
  include FeedbackExchangeContract

  STATE_PATH = "/_pact/provider-states"

  B1 = "00000000-0000-7000-8000-0000000000b1"
  C1 = "00000000-0000-7000-8000-0000000000c1"
  D1 = "00000000-0000-7000-8000-0000000000d1"
  D2 = "00000000-0000-7000-8000-0000000000d2"
  D3 = "00000000-0000-7000-8000-0000000000d3"
  PAGED = {
    "00000000-0000-7000-8000-0000000000a1" => [ "2026-10-20T23:00:00.000000Z", "First of three." ],
    "00000000-0000-7000-8000-0000000000a2" => [ "2026-10-20T23:01:00.000000Z", "Second of three." ],
    "00000000-0000-7000-8000-0000000000a3" => [ "2026-10-20T23:02:00.000000Z", "Third of three." ]
  }.freeze
  CONSENTED_TEXT = "Sam ran the **database cutover** calmly: rehearsed twice and kept everyone updated."

  # Answers the verifier's provider-state calls; everything else is the app.
  # Each state rolls the database back to where the test started, so no
  # interaction sees another's rows, and empties the replay store, because
  # Chip's pact presents the same signature in more than one interaction.
  class ProviderStates
    def initialize(app, replay_store, &seed)
      @app = app
      @replay_store = replay_store
      @seed = seed
      @savepoint = false
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == STATE_PATH

      change = JSON.parse(env["rack.input"].read)
      start_state(change["state"]) unless change["action"] == "teardown"
      [ 200, { "content-type" => "application/json" }, [ "{}" ] ]
    end

    private

    def start_state(state)
      connection = ActiveRecord::Base.connection
      connection.exec_rollback_to_savepoint("pact_state") if @savepoint
      connection.create_savepoint("pact_state")
      @savepoint = true
      @replay_store.clear
      @seed.call(state)
    end
  end

  setup do
    skip "Set CHIP_PACT_FILE, or run bin/rails contract:provider" if ENV["CHIP_PACT_FILE"].blank?

    travel_to Time.at(PACT_TIMESTAMP.to_i).utc
    @pact_file = pact_from(ENV.fetch("CHIP_PACT_FILE"))
    @replay_store = ActiveSupport::Cache::MemoryStore.new
  end

  # A /contract response carries the pact under `consumer_pact`; the verifier needs the pact alone.
  def pact_from(path)
    parsed = JSON.parse(File.read(path))
    return path unless parsed.key?("consumer_pact")

    assert_equal "v1", parsed["protocol"]
    dir = Rails.root.join("tmp/pact/provider").tap(&:mkpath)
    dir.join("chip-growthos.json").tap { |file| file.write(parsed["consumer_pact"].to_json) }.to_s
  end

  def seed(state)
    tenant = create(:tenant)
    tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(
      peer_name: "chip", base_url: "https://chip.example/chip/api/feedback-exchange", enabled: state != "the exchange is disabled"
    ))
    tenant.update_feedback_exchange!(inbound_secret: PACT_SECRET, outbound_secret: "growthos-outbound-#{'0' * 32}")

    ActsAsTenant.with_tenant(tenant) do
      @tenant = tenant
      marcus = person("marcus", "Marcus Manager")
      @priya = person("priya", "Priya Tester", manager: marcus, hibob: "3141")
      @sam = person("sam", "Sam Recipient", manager: marcus, hibob: "2718")
      @lena = person("lena", "Lena Tester", manager: marcus)
      @jo = person("jo", "Jo Recipient", manager: marcus)
      seed_feedback(state)
    end
  end

  def seed_feedback(state)
    case state
    when "the exchange is disabled", "no feedback is waiting"
      nil
    when "priya.test has given sam.test consented feedback", "priya.test's feedback to sam.test can be acknowledged"
      feedback(B1, given_at: "2026-10-20T22:00:00.123456Z", updated_at: "2026-10-20T22:00:00.234567Z", content: CONSENTED_TEXT)
    when "priya.test's feedback to sam.test was edited"
      feedback(B1, given_at: "2026-10-20T22:00:00.123456Z", updated_at: "2026-10-20T23:30:00.345678Z",
                   content: "Sam ran the **database cutover** calmly: rehearsed twice, wrote the rollback plan and kept everyone updated.")
    when "priya.test's feedback to sam.test was withdrawn"
      feedback(B1, given_at: "2026-10-20T22:00:00.123456Z", updated_at: "2026-10-20T23:40:00.456789Z", content: CONSENTED_TEXT,
                   link_status: "withdrawn")
    when "lena.test has recorded an observation for jo.test"
      feedback(C1, author: @lena, recipient: @jo, evidence_type: "observation", given_at: "2026-10-20T21:00:00.111111Z",
                   updated_at: "2026-10-20T21:00:00.222222Z", content: "Jo paired with a new starter all week and wrote up what they learned.")
    when "priya.test has answered sam.test's request in a period"
      answered_request
    when "more feedback is waiting than fits one page"
      PAGED.each { |id, (at, content)| feedback(id, given_at: at, updated_at: at, content: content) }
    else
      raise "No provider state #{state.inspect}: agree it with Chip first (docs/guidelines/feedback-exchange.md)"
    end
  end

  def person(name, display_name, manager: nil, hibob: nil)
    create(:person, tenant: @tenant, email: "#{name}.test@meandu.com", name: display_name, manager: manager,
                    hris_source: hibob && "hibob", external_id: hibob)
  end

  # Unplaced feedback, as a person recorded it: the columns the feed reads.
  def feedback(id, given_at:, updated_at:, content:, author: @priya, recipient: @sam, evidence_type: "peer_feedback", **attrs)
    item = create(:evidence_item, id: id, tenant: @tenant, author: author, person_id: recipient.id, source: "peer",
                                  evidence_type: evidence_type, content: content, recorded_at: Time.iso8601(given_at),
                                  capability_stable_id: nil, level_ordinal: nil, with_link: false, **attrs)
    item.update_columns(updated_at: Time.iso8601(updated_at))
    item
  end

  def answered_request
    cycle = create(:assessment_cycle, tenant: @tenant, cycle_id: D3, name: "Q4 2026")
    item = feedback(D1, given_at: "2026-10-20T20:00:00.333333Z", updated_at: "2026-10-20T20:00:00.444444Z",
                        content: "Consistently raised the bar on test quality during Q4.", cycle_id: cycle.cycle_id,
                        framework_id: cycle.framework_id)
    create(:evidence_request, id: D2, tenant: @tenant, requester: @sam, requestee: @priya, person_id: @sam.id,
                              framework_id: cycle.framework_id, status: "responded", evidence_id: item.id,
                              responded_at: Time.iso8601("2026-10-20T20:00:00.333333Z"),
                              message: "Could you share how Sam handled the database cutover? A concrete example helps most.")
  end

  should "honour every interaction in Chip's pact" do
    app = ProviderStates.new(Rails.application, @replay_store) { |state| seed(state) }
    Capybara.server = :puma, { Silent: true }
    server = Capybara::Server.new(app, host: "127.0.0.1").boot

    passed, = Rails.stub(:cache, @replay_store) do
      PactContract.verify(pact_file: @pact_file, provider: "growthos", base_url: "http://127.0.0.1:#{server.port}",
                          state_change_url: "http://127.0.0.1:#{server.port}#{STATE_PATH}")
    end

    # The verifier prints its own report, failures included, above this line.
    assert passed, "GrowthOS does not honour Chip's pact (#{@pact_file}); the verifier's report is above"
  end
end
