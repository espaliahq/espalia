# frozen_string_literal: true

require "test_helper"

class Hris::Hibob::WebhookValidatorTest < ActiveSupport::TestCase
  context ".valid?" do
    should "return true for a valid Base64-encoded HMAC-SHA512 signature" do
      secret = "webhook-secret-key"
      payload = '{"event":"employee.updated","data":{"id":"123"}}'
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA512", secret, payload))

      assert Hris::Hibob::WebhookValidator.valid?(
        payload: payload,
        signature: signature,
        secret: secret
      )
    end

    should "return false when given a hex-encoded signature instead of Base64" do
      secret = "webhook-secret-key"
      payload = '{"event":"employee.updated","data":{"id":"123"}}'
      hex_signature = OpenSSL::HMAC.hexdigest("SHA512", secret, payload)

      assert_not Hris::Hibob::WebhookValidator.valid?(
        payload: payload,
        signature: hex_signature,
        secret: secret
      )
    end

    should "return false for an invalid signature" do
      assert_not Hris::Hibob::WebhookValidator.valid?(
        payload: '{"event":"test"}',
        signature: "bad-signature",
        secret: "secret"
      )
    end

    should "return false when payload is blank" do
      assert_not Hris::Hibob::WebhookValidator.valid?(
        payload: "",
        signature: "sig",
        secret: "secret"
      )
    end

    should "return false when signature is blank" do
      assert_not Hris::Hibob::WebhookValidator.valid?(
        payload: "body",
        signature: "",
        secret: "secret"
      )
    end

    should "return false when secret is blank" do
      assert_not Hris::Hibob::WebhookValidator.valid?(
        payload: "body",
        signature: "sig",
        secret: ""
      )
    end
  end
end
