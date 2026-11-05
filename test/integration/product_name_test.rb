# frozen_string_literal: true

require "test_helper"

# The product's display name comes from config.x.product_name (#660), so an
# instance can run under its own identity by setting PRODUCT_NAME.
class ProductNameTest < ActionDispatch::IntegrationTest
  setup do
    @original = Rails.application.config.x.product_name
    Rails.application.config.x.product_name = "Acme Growth"
  end

  teardown do
    Rails.application.config.x.product_name = @original
  end

  context "the sign-in page" do
    should "take its heading, title and application-name from the config" do
      get new_user_session_path

      assert_response :success
      assert_includes response.body, ">Acme Growth</h1>"
      assert_includes response.body, %(<meta name="application-name" content="Acme Growth">)
      assert_includes response.body, "<title>Acme Growth</title>"
    end
  end
end
