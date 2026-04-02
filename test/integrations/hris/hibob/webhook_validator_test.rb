# frozen_string_literal: true

require "test_helper"

class Hris::Hibob::WebhookValidatorTest < ActiveSupport::TestCase
  context ".valid?" do
    should "return true for a valid HMAC-SHA512 signature" do
      secret = "webhook-secret-key"
      payload = '{"event":"employee.updated","data":{"id":"123"}}'
      signature = OpenSSL::HMAC.hexdigest("SHA512", secret, payload)

      assert Hris::Hibob::WebhookValidator.valid?(
        payload: payload,
        signature: signature,
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
