# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::ContractsControllerTest < ActionDispatch::IntegrationTest
  PATH = "/api/feedback_exchange/feedback/contract"

  should "serve the committed consumer pact to an unsigned request" do
    get PATH

    assert_response :success
    assert_equal "v1", response.parsed_body["protocol"]
    assert_equal Rails.application.config.x.release_id, response.parsed_body["build"]
    assert_equal JSON.parse(Rails.root.join("contract/pacts/growthos-chip.json").read), response.parsed_body["consumer_pact"]
  end

  should "name growthos as consumer and chip as provider" do
    get PATH

    pact = response.parsed_body["consumer_pact"]
    assert_equal [ "growthos", "chip" ], [ pact.dig("consumer", "name"), pact.dig("provider", "name") ]
  end

  should "serve it while every tenant has the exchange switched off" do
    tenant = create(:tenant)
    tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(enabled: false, peer_name: "chip", base_url: "https://chip.example.com/api"))

    get PATH

    assert_response :success
  end

  should "let caches keep it" do
    get PATH

    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "max-age=300"
  end
end
