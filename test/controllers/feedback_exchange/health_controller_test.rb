# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::HealthControllerTest < ActionDispatch::IntegrationTest
  INBOUND = "inbound-secret-inbound-secret-inbound"
  PATH = "/api/feedback_exchange/health"

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @tenant = create(:tenant)
    @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(
      enabled: true, peer_name: "chip", base_url: "https://chip.example.com/api"
    ))
    @tenant.update_feedback_exchange_secrets!(outbound_secret: "outbound-secret-outbound-secret-xx", inbound_secret: INBOUND)
  end

  def signed_headers(secret: INBOUND, method: "GET", path: PATH, body: "", timestamp: Time.now.to_i.to_s)
    {
      "X-Exchange-Timestamp" => timestamp,
      "X-Exchange-Signature" => FeedbackExchange::Signature.sign(
        secret: secret, method: method, path_with_query: path, body: body, timestamp: timestamp
      ),
      "X-Exchange-Consumer" => "chip"
    }
  end

  def get_health(headers: signed_headers, path: PATH)
    Rails.stub(:cache, @cache) { get path, headers: headers }
  end

  should "answer 200 with the peer name to a signed request" do
    get_health

    assert_response :success
    assert_equal({ "ok" => true, "peer" => "chip" }, response.parsed_body)
  end

  should "run the action in the signing tenant" do
    other = create(:tenant)
    other.update_feedback_exchange_secrets!(inbound_secret: "someone-elses-secret")
    other.update!(feedback_exchange_config: FeedbackExchangeConfig.new(enabled: true, peer_name: "acme", base_url: "https://acme.example.com"))

    get_health

    assert_equal "chip", response.parsed_body["peer"]
  end

  should "resolve a different tenant from a different secret" do
    other = create(:tenant)
    other.update!(feedback_exchange_config: FeedbackExchangeConfig.new(enabled: true, peer_name: "acme", base_url: "https://acme.example.com"))
    other.update_feedback_exchange_secrets!(inbound_secret: "someone-elses-secret")

    get_health(headers: signed_headers(secret: "someone-elses-secret"))

    assert_equal "acme", response.parsed_body["peer"]
  end

  should "refuse an unsigned request with 401" do
    get_health(headers: {})
    assert_response :unauthorized
  end

  should "refuse a wrong secret with 401" do
    get_health(headers: signed_headers(secret: "wrong"))
    assert_response :unauthorized
  end

  should "refuse a stale timestamp with 401" do
    get_health(headers: signed_headers(timestamp: (Time.now.to_i - 600).to_s))
    assert_response :unauthorized
  end

  should "refuse a signature made for another path with 401" do
    get_health(headers: signed_headers(path: "/api/feedback_exchange/feedback"))
    assert_response :unauthorized
  end

  should "refuse a signature made for another method with 401" do
    get_health(headers: signed_headers(method: "POST"))
    assert_response :unauthorized
  end

  should "refuse a replay of the same signed request with 401" do
    headers = signed_headers

    get_health(headers: headers)
    assert_response :success

    get_health(headers: headers)
    assert_response :unauthorized
  end

  should "answer 404 to a verified request while the exchange is disabled" do
    @tenant.update!(feedback_exchange_config: @tenant.feedback_exchange_config.tap { |c| c.enabled = false })

    get_health

    assert_response :not_found
  end

  should "still answer 401 to an unsigned request while disabled" do
    @tenant.update!(feedback_exchange_config: @tenant.feedback_exchange_config.tap { |c| c.enabled = false })

    get_health(headers: {})

    assert_response :unauthorized
  end

  should "accept the previous secret inside the rotation window" do
    freeze_time do
      @tenant.update_feedback_exchange_secrets!(inbound_secret: "the-new-inbound-secret")

      get_health(headers: signed_headers(secret: INBOUND))
      assert_response :success
    end
  end

  should "refuse the previous secret once the window has passed" do
    @tenant.update_feedback_exchange_secrets!(inbound_secret: "the-new-inbound-secret")

    travel 25.hours do
      get_health(headers: signed_headers(secret: INBOUND))
      assert_response :unauthorized
    end
  end
end
