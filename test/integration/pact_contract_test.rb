# frozen_string_literal: true

require "test_helper"
require "net/http"
require_relative "../support/pact_contract"

# The Minitest wrapper over pact_ffi (test/support/pact_contract.rb): what it
# hands pact-ffi must come out as a pact a peer's verifier reads as intended.
class PactContractTest < ActiveSupport::TestCase
  should "keep a matcher nested in an array a matcher, not its pairs" do
    notified = PactContract.each_like(PactContract.term("^(author|recipient)$", "author"))

    assert_equal [ { "pact:matcher:type" => "regex", "regex" => "^(author|recipient)$", "value" => "author" } ], notified["value"]
    assert_equal [ "a", "b" ], PactContract.each_like(%w[a b])["value"]
  end

  should "write a nested matcher as an example and a rule" do
    Dir.mktmpdir do |dir|
      pact = PactContract::Consumer.new(consumer: "growthos", provider: "peer", pact_dir: dir)
      pact.upon_receiving("a nested matcher", given: "a state") do |i|
        i.request "GET", "/items"
        i.response 200, body: { items: PactContract.each_like({ kind: PactContract.term("^(a|b)$", "a") }) }
      end
      pact.run { |base_url| Net::HTTP.get_response(URI("#{base_url}/items")) }

      response = JSON.parse(File.read(File.join(dir, "growthos-peer.json"))).dig("interactions", 0, "response")
      assert_equal({ "items" => [ { "kind" => "a" } ] }, response["body"])
      assert_equal [ { "match" => "regex", "regex" => "^(a|b)$" } ], response.dig("matchingRules", "body", "$.items[*].kind", "matchers")
    end
  end
end
