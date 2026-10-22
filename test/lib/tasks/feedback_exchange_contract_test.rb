# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/tasks/feedback_exchange_contract")

class FeedbackExchangeContractTasksTest < ActiveSupport::TestCase
  URL = "https://chip.example/chip/api/feedback-exchange/feedback/contract"
  Response = FeedbackExchangeContractTasks::Response

  def contract(interactions: [ { "description" => "one" } ], consumer: "chip", provider: "growthos", protocol: "v1")
    { "protocol" => protocol, "build" => "abc123",
      "consumer_pact" => { "consumer" => { "name" => consumer }, "provider" => { "name" => provider },
                           "interactions" => interactions, "metadata" => { "pactSpecification" => { "version" => "3.0.0" } } } }
  end

  def resolve(response = nil, url: URL, fresh: false, now: @now)
    fetch = lambda do |_url|
      @calls += 1
      response || raise("no fetch expected")
    end
    FeedbackExchangeContractTasks::PeerContract.new(url: url, cache_file: @cache, fresh: fresh, fetch: fetch, now: now).resolve
  end

  def cache!(fetched_at)
    @cache.write(contract.merge("fetched_at" => fetched_at.iso8601, "source_url" => URL).to_json)
  end

  def check(committed, deployed: nil, status: 200, labelled: false, url: URL)
    response = Response.new(status: status, body: { "consumer_pact" => deployed }.to_json)
    FeedbackExchangeContractTasks::ContractChange.check(committed: committed, url: url, labelled: labelled, fetch: ->(_) { response })
  end

  context "PeerContract" do
    setup do
      @dir = Pathname(Dir.mktmpdir)
      @cache = @dir.join("chip.json")
      @now = Time.utc(2026, 10, 22, 12)
      @calls = 0
    end

    teardown { FileUtils.rm_rf(@dir) }

    should "have nothing to verify while no URL is set" do
      result = resolve(url: nil)

      assert_nil result.pact_file
      assert_equal 0, @calls
    end

    should "fetch, check and cache Chip's contract" do
      result = resolve(Response.new(status: 200, body: contract.to_json))

      assert_equal @cache.to_s, result.pact_file
      cached = JSON.parse(@cache.read)
      assert_equal [ "chip", URL, @now.iso8601 ], [ cached.dig("consumer_pact", "consumer", "name"), cached["source_url"], cached["fetched_at"] ]
    end

    should "use a copy younger than a day without fetching" do
      cache!(@now - 23.hours)

      assert_equal @cache.to_s, resolve.pact_file
      assert_equal 0, @calls
    end

    should "fetch again once the copy is a day old, or when told to" do
      cache!(@now - 25.hours)
      resolve(Response.new(status: 200, body: contract.to_json))

      cache!(@now - 1.hour)
      resolve(Response.new(status: 200, body: contract.to_json), fresh: true)

      assert_equal 2, @calls
    end

    should "fall back to an old copy with a warning when the fetch fails" do
      cache!(@now - 3.days)

      result = resolve(Response.new(status: 503, body: "down"))

      assert_equal @cache.to_s, result.pact_file
      assert_match(/answered 503/, result.warnings.sole)
    end

    should "have nothing to verify before Chip publishes" do
      assert_nil resolve(Response.new(status: 404, body: "")).pact_file
    end

    should "fail when the fetch fails and there is no copy" do
      assert_raises(FeedbackExchangeContractTasks::PeerContract::Unavailable) { resolve(Response.new(status: nil, body: "SocketError")) }
    end

    should "refuse a contract between other parties, in another protocol or not JSON, even with a copy to fall back on" do
      cache!(@now - 3.days)

      [ contract(consumer: "growthos", provider: "chip").to_json, contract(protocol: "v2").to_json, "{}", "<html>" ].each do |body|
        assert_raises(FeedbackExchangeContractTasks::PeerContract::Unavailable) { resolve(Response.new(status: 200, body: body)) }
      end
    end

    should "ignore a copy fetched from another address, or one that does not say when" do
      cache!(@now - 1.hour)
      resolve(Response.new(status: 200, body: contract.to_json), url: "https://chip-staging.example/contract")

      @cache.write(contract.to_json)
      resolve(Response.new(status: 200, body: contract.to_json))

      assert_equal 2, @calls
    end
  end

  context "ContractChange" do
    setup { @pact = contract(consumer: "growthos", provider: "chip", interactions: [ { "b" => 1, "a" => 2 }, { "c" => 3 } ])["consumer_pact"] }

    should "pass when only the order or the library versions differ" do
      reordered = @pact.merge("interactions" => [ { "c" => 3 }, { "a" => 2, "b" => 1 } ], "metadata" => @pact["metadata"].merge("pactRust" => { "ffi" => "9" }))

      assert_equal :pass, check(@pact, deployed: reordered).first
    end

    should "fail a changed pact without the label, and pass it with one" do
      changed = @pact.merge("interactions" => [ { "c" => 4 } ])

      assert_equal :fail, check(changed, deployed: @pact).first
      assert_equal :pass, check(changed, deployed: @pact, labelled: true).first
    end

    should "warn, not fail, before our /contract is deployed or while no URL is set" do
      assert_equal :warn, check(@pact, status: 404).first
      assert_equal :warn, check(@pact, url: nil).first
    end

    should "fail when the deployed contract cannot be read" do
      assert_equal :fail, check(@pact, status: 502).first
    end
  end
end
