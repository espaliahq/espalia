# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::DeletionsControllerTest < ActionDispatch::IntegrationTest
  include FeedbackExchangeProducerHelpers

  PATH = "#{FEED_PATH}/deletions"

  setup { setup_exchange_tenant }
  teardown { ActsAsTenant.current_tenant = nil }

  should "always be empty, because Espalia withdraws and never deletes" do
    author = create_person("a@example.com")
    item = create_item(author: author, recipient: create_person("r@example.com"), link_status: "withdrawn")

    signed_get(PATH)

    assert_response :success
    assert_equal({ "items" => [], "next_cursor" => nil, "has_more" => false }, response.parsed_body)
    assert_not_includes response.body, item.id
  end

  should "hand the caller's cursor back" do
    signed_get("#{PATH}?since=abc")

    assert_equal "abc", response.parsed_body["next_cursor"]
  end

  should "echo no cursor that is not a plain string" do
    signed_get("#{PATH}?since[]=a&since[]=b")

    assert_nil response.parsed_body["next_cursor"]
  end

  should "refuse an unsigned request" do
    get PATH
    assert_response :unauthorized
  end

  should "answer 404 while the exchange is disabled" do
    @tenant.update!(feedback_exchange_config: @tenant.feedback_exchange_config.tap { |config| config.enabled = false })

    signed_get(PATH)

    assert_response :not_found
  end
end
