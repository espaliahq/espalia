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
    @tenant.update_feedback_exchange!(outbound_secret: "outbound-secret-outbound-secret-xx", inbound_secret: INBOUND)
  end

  def signed_headers(secret: INBOUND, method: "GET", path: PATH, body: "", timestamp: Time.now.to_i.to_s, consumer: "chip")
    {
      "X-Exchange-Timestamp" => timestamp,
      "X-Exchange-Signature" => FeedbackExchange::Signature.sign(
        secret: secret, method: method, path_with_query: path, body: body, timestamp: timestamp
      ),
      "X-Exchange-Consumer" => consumer
    }.compact
  end

  def get_health(headers: signed_headers, path: PATH)
    Rails.stub(:cache, @cache) { get path, headers: headers }
  end

  def key_id_header(secret = INBOUND) = { "X-Exchange-Key-Id" => FeedbackExchange::Signature.key_id(secret) }

  context "with a key id" do
    should "verify only the tenant it names" do
      other = create(:tenant)
      other.update!(feedback_exchange_config: FeedbackExchangeConfig.new(enabled: true, peer_name: "acme", base_url: "https://acme.example.com"))
      other.update_feedback_exchange!(inbound_secret: "someone-elses-inbound-secret-0123456789")

      get_health(headers: signed_headers.merge(key_id_header))
      assert_response :success
      assert_equal "chip", response.parsed_body["peer"]
    end

    should "refuse a key id that belongs to another tenant than the secret" do
      other = create(:tenant)
      other.update_feedback_exchange!(inbound_secret: "someone-elses-inbound-secret-0123456789")

      get_health(headers: signed_headers.merge(key_id_header("someone-elses-inbound-secret-0123456789")))
      assert_response :unauthorized
    end

    should "refuse an unknown or malformed key id without trying any tenant" do
      [ "0123456789abcdef", "nope", "", "0123456789abcdeg" ].each do |bad|
        @cache.clear
        get_health(headers: signed_headers.merge("X-Exchange-Key-Id" => bad))
        assert_response :unauthorized, "expected key id #{bad.inspect} to be refused"
      end
    end

    should "accept an upper-case key id" do
      get_health(headers: signed_headers.merge("X-Exchange-Key-Id" => FeedbackExchange::Signature.key_id(INBOUND).upcase))
      assert_response :success
    end

    should "find the tenant by its previous secret's key id inside the rotation window" do
      @tenant.update_feedback_exchange!(inbound_secret: "the-new-inbound-secret-0123456789abcdef")

      get_health(headers: signed_headers(secret: INBOUND).merge(key_id_header(INBOUND)))
      assert_response :success
    end

    should "not load every tenant" do
      loaded = []
      Tenant.stub(:where, ->(*args, **kw) { loaded << args; Tenant.unscoped.where(*args, **kw) }) do
        get_health(headers: signed_headers.merge(key_id_header))
      end
      assert_response :success
      assert(loaded.any? { |args| args.first.to_s.include?("inbound_key_id") })
      assert(loaded.none? { |args| args.first.is_a?(Hash) && args.first.key?(:feedback_exchange_credentials) })
    end
  end

  should "still serve a peer that sends no key id" do
    get_health(headers: signed_headers)
    assert_response :success
  end

  should "answer 200 with the peer name to a signed request" do
    get_health

    assert_response :success
    assert_equal({ "ok" => true, "peer" => "chip" }, response.parsed_body)
  end

  should "run the action in the signing tenant" do
    other = create(:tenant)
    other.update_feedback_exchange!(inbound_secret: "someone-elses-secret-0123456789abcdef0123456789")
    other.update!(feedback_exchange_config: FeedbackExchangeConfig.new(enabled: true, peer_name: "acme", base_url: "https://acme.example.com"))

    get_health

    assert_equal "chip", response.parsed_body["peer"]
  end

  should "resolve a different tenant from a different secret" do
    other = create(:tenant)
    other.update!(feedback_exchange_config: FeedbackExchangeConfig.new(enabled: true, peer_name: "acme", base_url: "https://acme.example.com"))
    other.update_feedback_exchange!(inbound_secret: "someone-elses-secret-0123456789abcdef0123456789")

    get_health(headers: signed_headers(secret: "someone-elses-secret-0123456789abcdef0123456789", consumer: "acme"))

    assert_equal "acme", response.parsed_body["peer"]
  end

  should "refuse a request that does not name its consumer with 401" do
    get_health(headers: signed_headers(consumer: nil))
    assert_response :unauthorized
  end

  should "refuse a consumer other than the tenant's peer with 401" do
    get_health(headers: signed_headers(consumer: "acme"))
    assert_response :unauthorized
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

  should "refuse a replay for as long as the timestamp is still acceptable" do
    ahead = (Time.now.to_i + 290).to_s
    headers = signed_headers(timestamp: ahead)

    get_health(headers: headers)
    assert_response :success

    travel 301.seconds do
      get_health(headers: headers)
      assert_response :unauthorized
    end
  end

  should "refuse a stale timestamp before looking at any tenant" do
    Tenant.stub(:where, ->(*) { flunk "no tenant should be loaded for a stale request" }) do
      get_health(headers: signed_headers(timestamp: (Time.now.to_i - 3600).to_s))
    end

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
      @tenant.update_feedback_exchange!(inbound_secret: "the-new-inbound-secret-0123456789abcdef0123456789")

      get_health(headers: signed_headers(secret: INBOUND))
      assert_response :success
    end
  end

  should "refuse the previous secret once the window has passed" do
    @tenant.update_feedback_exchange!(inbound_secret: "the-new-inbound-secret-0123456789abcdef0123456789")

    travel 25.hours do
      get_health(headers: signed_headers(secret: INBOUND))
      assert_response :unauthorized
    end
  end
end
