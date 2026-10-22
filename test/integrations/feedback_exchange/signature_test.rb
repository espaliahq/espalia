# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::SignatureTest < ActiveSupport::TestCase
  SECRET = "s3cret-s3cret-s3cret-s3cret-s3cret"
  PATH = "/api/feedback_exchange/feedback?limit=1&since=abc"

  def sign(secret: SECRET, method: "GET", path: PATH, body: "", timestamp: @now.to_i.to_s)
    FeedbackExchange::Signature.sign(secret: secret, method: method, path_with_query: path, body: body, timestamp: timestamp)
  end

  def verify(signature, secret: SECRET, method: "GET", path: PATH, body: "", timestamp: @now.to_i.to_s, **rest)
    FeedbackExchange::Signature.verify(
      signature: signature, timestamp: timestamp, secret: secret, method: method,
      path_with_query: path, body: body, now: @now, **rest
    )
  end

  setup { @now = Time.zone.local(2026, 10, 20, 9, 0, 0) }

  context ".sign" do
    should "follow the protocol's signing string" do
      ts = "1760950800"
      string = "v1:#{ts}:GET:#{PATH}:#{Digest::SHA256.hexdigest('')}"
      expected = "v1=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, string)}"

      assert_equal expected, sign(timestamp: ts)
    end

    should "hash the body into the signature" do
      assert_not_equal sign(body: "{}"), sign(body: "{ }")
    end

    should "upcase the method" do
      assert_equal sign(method: "GET"), sign(method: "get")
    end
  end

  # Chip computed these in TypeScript for the contract tests (its pacts record
  # them), so matching them proves the two implementations sign alike.
  context "with the contract tests' shared secret and clock" do
    should "sign as Chip does" do
      secret = "pact-test-secret-0123456789abcdef0123456789abcdef"

      assert_equal "e6bf4220007d6a9a", FeedbackExchange::Signature.key_id(secret)
      assert_equal "v1=af80da59ae8bcce16233ef19a0ae43a48e532cd2274e2fb8b2b9a7593a18876f",
                   sign(secret: secret, path: "/chip/api/feedback-exchange/feedback?limit=100", timestamp: "1792540800")
      assert_equal "v1=f8680e0b6174b24374be1d8d7140d626ca048991f81b8aafef33979dfc650789",
                   sign(secret: secret, path: "/api/feedback_exchange/feedback?limit=100", timestamp: "1792540800")
    end
  end

  context ".key_id" do
    should "be the first 16 hex characters of the secret's SHA-256" do
      assert_equal Digest::SHA256.hexdigest(SECRET)[0, 16], FeedbackExchange::Signature.key_id(SECRET)
      assert_match(FeedbackExchange::Signature::KEY_ID_FORMAT, FeedbackExchange::Signature.key_id(SECRET))
    end

    should "differ between secrets" do
      assert_not_equal FeedbackExchange::Signature.key_id("a" * 32), FeedbackExchange::Signature.key_id("b" * 32)
    end
  end

  context ".verify" do
    should "round trip" do
      assert verify(sign)
    end

    should "round trip a body" do
      assert verify(sign(method: "POST", body: '{"items":[]}'), method: "POST", body: '{"items":[]}')
    end

    should "refuse the wrong secret" do
      assert_not verify(sign(secret: "someone-else"))
    end

    should "refuse missing headers" do
      assert_not verify(nil)
      assert_not verify("")
      assert_not verify(sign, timestamp: nil)
    end

    should "refuse a stale or future timestamp" do
      assert_not verify(sign(timestamp: (@now - 301).to_i.to_s), timestamp: (@now - 301).to_i.to_s)
      assert_not verify(sign(timestamp: (@now + 301).to_i.to_s), timestamp: (@now + 301).to_i.to_s)
    end

    should "accept a timestamp at the edge of the window" do
      ts = (@now - 300).to_i.to_s
      assert verify(sign(timestamp: ts), timestamp: ts)
    end

    should "refuse a timestamp that is not a number" do
      assert_not verify(sign(timestamp: "yesterday"), timestamp: "yesterday")
    end

    should "refuse a tampered body" do
      assert_not verify(sign(method: "POST", body: "a"), method: "POST", body: "b")
    end

    should "refuse a swapped method" do
      assert_not verify(sign(method: "GET"), method: "POST")
    end

    should "refuse a swapped path or query" do
      assert_not verify(sign, path: "/api/feedback_exchange/feedback/ack?limit=1&since=abc")
      assert_not verify(sign, path: "/api/feedback_exchange/feedback?limit=2&since=abc")
    end

    should "refuse a signature without the version prefix" do
      assert_not verify(sign.delete_prefix("v1="))
    end

    context "during a rotation" do
      should "accept the previous secret inside 24 hours" do
        signature = sign(secret: "old-secret")

        assert verify(signature, secret: "new-secret", previous_secret: "old-secret", previous_rotated_at: @now - 23.hours)
      end

      should "refuse the previous secret after 24 hours" do
        signature = sign(secret: "old-secret")

        assert_not verify(signature, secret: "new-secret", previous_secret: "old-secret", previous_rotated_at: @now - 25.hours)
      end

      should "refuse the previous secret when no rotation time is recorded" do
        assert_not verify(sign(secret: "old-secret"), secret: "new-secret", previous_secret: "old-secret")
      end

      should "keep accepting the current secret" do
        assert verify(sign(secret: "new-secret"), secret: "new-secret", previous_secret: "old-secret", previous_rotated_at: @now - 1.hour)
      end
    end
  end
end
