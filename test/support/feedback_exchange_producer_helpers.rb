# frozen_string_literal: true

# Setup and signing shared by the producer endpoint tests: a tenant whose
# exchange is on, and requests signed the way a peer signs them.
module FeedbackExchangeProducerHelpers
  INBOUND = "inbound-secret-inbound-secret-inbound"
  FEED_PATH = "/api/feedback_exchange/feedback"

  def setup_exchange_tenant
    @cache = ActiveSupport::Cache::MemoryStore.new
    @tenant = create(:tenant)
    @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(
      enabled: true, peer_name: "chip", base_url: "https://chip.example.com/api"
    ))
    @tenant.update_feedback_exchange!(outbound_secret: "outbound-secret-outbound-secret-xx", inbound_secret: INBOUND)
    ActsAsTenant.current_tenant = @tenant
  end

  def signed_headers(method: "GET", path: FEED_PATH, body: "", secret: INBOUND, timestamp: Time.now.to_i.to_s, consumer: "chip")
    {
      "X-Exchange-Timestamp" => timestamp,
      "X-Exchange-Signature" => FeedbackExchange::Signature.sign(
        secret: secret, method: method, path_with_query: path, body: body, timestamp: timestamp
      ),
      "X-Exchange-Consumer" => consumer
    }.compact
  end

  # @return [ActiveSupport::Parameters] nothing; the response is read from the integration session
  def signed_get(path = FEED_PATH, **options)
    Rails.stub(:cache, @cache) { get path, headers: signed_headers(path: path, **options) }
  end

  def signed_post(path, payload, **options)
    body = payload.is_a?(String) ? payload : payload.to_json
    headers = signed_headers(method: "POST", path: path, body: body, **options).merge("Content-Type" => "application/json")
    Rails.stub(:cache, @cache) { post path, params: body, headers: headers }
  end

  def feed_ids
    response.parsed_body["items"].map { |item| item["id"] }
  end

  def create_person(email, **attrs)
    create(:person, tenant: @tenant, email: email, name: email.split("@").first.capitalize, **attrs)
  end

  # A peer feedback item from `author` to `recipient`, eligible for the feed
  # unless an option says otherwise.
  #
  # Written straight to the column, as the importer's projection writes it.
  def create_item(author:, recipient:, external_reference: nil, **attrs)
    item = create(:evidence_item, tenant: @tenant, author: author, person_id: recipient.id,
                                  source: "peer", evidence_type: "peer_feedback", **attrs)
    item.update_column(:external_reference, external_reference) if external_reference
    item
  end
end
