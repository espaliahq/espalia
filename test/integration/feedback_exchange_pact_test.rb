# frozen_string_literal: true

require "test_helper"
require_relative "../support/feedback_exchange_contract"

# Our consumer pact of Chip is served publicly at /contract, so it may name
# only the contract tests' synthetic people and example hosts, and every
# request in it must be one Chip's verifier can check.
class FeedbackExchangePactTest < ActiveSupport::TestCase
  include FeedbackExchangeContract

  SYNTHETIC_EMAILS = %w[priya sam marcus lena jo].map { |name| "#{name}.test@meandu.com" }.freeze
  CHIP_STATES = [
    "the exchange is disabled",
    "no feedback is waiting",
    "priya.test has given sam.test consented feedback",
    "marcus.test has given sam.test consented feedback",
    "lena.test has given sam.test feedback without manager consent",
    "priya.test's feedback to sam.test was edited",
    "priya.test has answered sam.test's request in a period",
    "priya.test's feedback to sam.test was deleted",
    "priya.test's feedback to sam.test can be acknowledged"
  ].freeze

  setup do
    @raw = COMMITTED_PACT.read
    @pact = JSON.parse(@raw)
  end

  should "be a V3 pact from growthos to chip" do
    assert_equal [ "growthos", "chip", "3.0.0" ],
                 [ @pact.dig("consumer", "name"), @pact.dig("provider", "name"), @pact.dig("metadata", "pactSpecification", "version") ]
    assert_not_empty @pact["interactions"], "run bin/rails contract:consumer"
  end

  should "name only the synthetic people and example hosts" do
    assert_empty @raw.scan(/[\w.+-]+@[\w.-]+/).uniq - SYNTHETIC_EMAILS
    hosts = @raw.scan(%r{https?://([^/"\\]+)}).flatten.uniq
    assert_empty hosts.reject { |host| host.end_with?(".example") }, "use chip.example or growthos.example"
  end

  should "use only the provider states agreed with Chip" do
    states = @pact["interactions"].flat_map { |interaction| interaction["providerStates"].pluck("name") }

    assert_empty states.uniq - CHIP_STATES, "agree a new state with Chip first, then add it here"
  end

  should "sign every request with the shared secret at the frozen clock" do
    @pact["interactions"].each do |interaction|
      headers = interaction.dig("request", "headers")
      assert_equal [ "growthos", PACT_TIMESTAMP ], headers.values_at("X-Exchange-Consumer", "X-Exchange-Timestamp"), interaction["description"]
    end
  end
end
