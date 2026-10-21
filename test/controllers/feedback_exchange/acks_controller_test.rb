# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::AcksControllerTest < ActionDispatch::IntegrationTest
  include FeedbackExchangeProducerHelpers

  PATH = "#{FEED_PATH}/ack"

  setup do
    setup_exchange_tenant
    @item = create_item(author: create_person("a@example.com"), recipient: create_person("r@example.com"))
    @payload = { items: [ { id: @item.id, remote_id: "chip-1", remote_url: "https://chip.example.com/feedback/1" } ] }
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "record where the item now also lives and answer 204" do
    signed_post(PATH, @payload)

    assert_response :no_content
    ack = FeedbackExchangeAck.sole
    assert_equal [ @item.id, "chip", "chip-1", "https://chip.example.com/feedback/1", @tenant.id ],
                 [ ack.evidence_id, ack.consumer, ack.remote_id, ack.remote_url, ack.tenant_id ]
  end

  should "be idempotent: a repeat leaves one row, and a changed link updates it" do
    signed_post(PATH, @payload)
    travel 1.second
    signed_post(PATH, @payload)
    assert_response :no_content
    assert_equal 1, FeedbackExchangeAck.count

    travel 1.second
    signed_post(PATH, { items: [ { id: @item.id, remote_id: "chip-2", remote_url: "https://chip.example.com/feedback/2" } ] })

    assert_response :no_content
    assert_equal "chip-2", FeedbackExchangeAck.sole.remote_id
  end

  should "refuse a consumer header that names another system than the tenant's peer" do
    signed_post(PATH, @payload, consumer: "other")

    assert_response :bad_request
    assert_equal 0, FeedbackExchangeAck.count
  end

  should "take the configured peer when the header is absent or differently cased" do
    signed_post(PATH, @payload, consumer: nil)
    assert_response :no_content
    assert_equal "chip", FeedbackExchangeAck.sole.consumer

    travel 1.second
    signed_post(PATH, { items: [ { id: @item.id, remote_id: "chip-2" } ] }, consumer: "CHIP")
    assert_response :no_content
    assert_equal "chip-2", FeedbackExchangeAck.sole.remote_id
  end

  should "accept an empty page and an unknown id without error" do
    signed_post(PATH, { items: [] })
    assert_response :no_content

    travel 1.second
    signed_post(PATH, { items: [ { id: SecureRandom.uuid_v7, remote_id: "x" } ] })
    assert_response :no_content
    assert_equal 0, FeedbackExchangeAck.count
  end

  should "refuse a malformed body with 400 and write nothing" do
    [ { items: "nope" }, { items: [ "nope" ] }, { items: [ { id: @item.id } ] },
      { items: [ { id: @item.id, remote_id: "x", remote_url: "javascript:alert(1)" } ] }, {} ].each do |payload|
      travel 1.second
      signed_post(PATH, payload)
      assert_response :bad_request, payload.inspect
    end
    signed_post(PATH, "{not json", timestamp: (Time.now.to_i + 1).to_s)
    assert_response :bad_request

    assert_equal 0, FeedbackExchangeAck.count
  end

  should "show the acknowledged item no differently in the feed" do
    signed_post(PATH, @payload)
    travel 1.second

    signed_get

    assert_equal [ @item.id ], feed_ids
  end

  should "refuse an unsigned request" do
    post PATH, params: @payload.to_json, headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_equal 0, FeedbackExchangeAck.count
  end

  should "refuse a body altered after signing" do
    headers = signed_headers(method: "POST", path: PATH, body: @payload.to_json).merge("Content-Type" => "application/json")
    tampered = { items: [ { id: @item.id, remote_id: "evil" } ] }.to_json

    Rails.stub(:cache, @cache) { post PATH, params: tampered, headers: headers }

    assert_response :unauthorized
    assert_equal 0, FeedbackExchangeAck.count
  end

  should "answer 404 while the exchange is disabled" do
    @tenant.update!(feedback_exchange_config: @tenant.feedback_exchange_config.tap { |config| config.enabled = false })

    signed_post(PATH, @payload)

    assert_response :not_found
    assert_equal 0, FeedbackExchangeAck.count
  end
end
