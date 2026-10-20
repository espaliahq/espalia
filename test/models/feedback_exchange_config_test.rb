# frozen_string_literal: true

require "test_helper"

class FeedbackExchangeConfigTest < ActiveSupport::TestCase
  context "defaults" do
    subject { FeedbackExchangeConfig.new }

    should "be off, with the standard export kinds and everything imported" do
      assert_equal "exchange", subject.provider
      assert_not subject.enabled?
      assert_not subject.suggestions_enabled?
      assert_empty subject.import_kinds
      assert_equal %w[peer_feedback manager_feedback observation impact], subject.export_kinds
    end
  end

  context "base_url" do
    should "accept https" do
      config = FeedbackExchangeConfig.new(base_url: "https://chip.example.com/api/feedback-exchange")
      assert config.valid?
    end

    should "refuse http outside development" do
      config = FeedbackExchangeConfig.new(base_url: "http://chip.example.com")
      assert_not config.valid?
      assert_includes config.errors[:base_url], "must start with https://"
    end

    should "accept http in development" do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
        assert FeedbackExchangeConfig.new(base_url: "http://rails-app:4000/api").valid?
      end
    end

    should "refuse other schemes and junk" do
      assert_not FeedbackExchangeConfig.new(base_url: "ftp://chip.example.com").valid?
      assert_not FeedbackExchangeConfig.new(base_url: "https://").valid?
      assert_not FeedbackExchangeConfig.new(base_url: "not a url").valid?
    end

    should "be optional while the exchange is off" do
      assert FeedbackExchangeConfig.new(base_url: "").valid?
    end

    should "be required once enabled" do
      config = FeedbackExchangeConfig.new(enabled: true, peer_name: "chip")
      assert_not config.valid?
      assert_not_empty config.errors[:base_url]
    end
  end

  context "peer_name" do
    should "accept a slug" do
      assert FeedbackExchangeConfig.new(peer_name: "chip").valid?
      assert FeedbackExchangeConfig.new(peer_name: "acme-feedback-2").valid?
    end

    should "refuse anything else" do
      %w[Chip chip_x chip.io -chip chip-].each do |name|
        assert_not FeedbackExchangeConfig.new(peer_name: name).valid?, "expected #{name} to be refused"
      end
    end
  end

  context "#normalized_base_url" do
    should "drop a trailing slash and whitespace" do
      assert_equal "https://a.example/x", FeedbackExchangeConfig.new(base_url: " https://a.example/x/ ").normalized_base_url
    end
  end

  context "#configured?" do
    setup do
      @tenant = create(:tenant)
      @config = FeedbackExchangeConfig.new(enabled: true, peer_name: "chip", base_url: "https://chip.example.com")
    end

    should "need both secrets" do
      assert_not @config.configured?(@tenant)
      @tenant.update_feedback_exchange_secrets!(outbound_secret: "a" * 32, inbound_secret: "b" * 32)
      assert @config.configured?(@tenant)
    end

    should "be false while disabled" do
      @tenant.update_feedback_exchange_secrets!(outbound_secret: "a" * 32, inbound_secret: "b" * 32)
      @config.enabled = false
      assert_not @config.configured?(@tenant)
    end
  end
end
