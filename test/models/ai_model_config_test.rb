# frozen_string_literal: true

require "test_helper"

class AiModelConfigTest < ActiveSupport::TestCase
  context "defaults" do
    subject { AiModelConfig.new }

    should "be an Anthropic config with suggestions off, names pseudonymised and low effort" do
      assert_equal "anthropic", subject.provider
      assert_not subject.suggestions_enabled?
      assert subject.pseudonymise_names?
      assert_equal "low", subject.effort
      assert subject.valid?
    end
  end

  context "validation" do
    should "only accept the known providers and efforts" do
      assert_not AiModelConfig.new(provider: "gemini").valid?
      assert_not AiModelConfig.new(effort: "extreme").valid?
      AiModelConfig::EFFORTS.each { |effort| assert AiModelConfig.new(effort: effort).valid?, effort }
      assert AiModelConfig.new(effort: "").valid?, "blank sends no effort"
    end

    should "need an address and a model for an OpenAI-compatible endpoint, but not for Anthropic" do
      config = AiModelConfig.new(provider: "openai_compatible")

      assert_not config.valid?
      assert_includes config.errors.full_messages, "Address can't be blank"
      assert_includes config.errors.full_messages, "Model can't be blank"
      assert AiModelConfig.new(provider: "anthropic").valid?
      assert AiModelConfig.new(provider: "openai_compatible", base_url: "https://gw.example.com/v1", model: "anthropic/claude-opus-5-5").valid?
    end

    should "need an address and a model for Jev, and point the gateway preset at it" do
      config = AiModelConfig.new(provider: "typesafe_jev")

      assert_not config.valid?
      assert_includes config.errors.full_messages, "Address can't be blank"
      preset = AiModelConfig::PRESETS.fetch("vercel_ai_gateway")
      assert AiModelConfig.new(preset.slice(:provider, :base_url, :model)).tap { |c| assert c.typesafe_jev? }.valid?
      assert_equal [ "typesafe_jev", "https://ai-gateway.vercel.sh/v1", "typesafe-ai/jev" ], preset.values_at(:provider, :base_url, :model)
      assert_equal "openai_compatible", AiModelConfig::PRESETS.dig("vercel_ai_gateway_chat", :provider)
    end

    should "accept provider-prefixed model ids and refuse anything with spaces or quotes" do
      %w[claude-opus-5-5 anthropic/claude-opus-5-5 openai/gpt-5:free meta-llama/Llama-3.3-70B@v1].each do |id|
        assert AiModelConfig.new(model: id).valid?, id
      end
      [ "two words", "x\"y", "a;b" ].each { |id| assert_not AiModelConfig.new(model: id).valid?, id }
    end

    should "refuse an address that is not https, carries a login or query, or is on a private network" do
      {
        "http://gw.example.com/v1" => "must start with https://",
        "ftp://gw.example.com" => "must start with https://",
        "https://user:pass@gw.example.com/v1" => "must be a plain address, with no login, query or fragment",
        "https://gw.example.com/v1?key=1" => "must be a plain address, with no login, query or fragment",
        "https://10.0.0.5/v1" => "must not be a private network address",
        "https://localhost:11434/v1" => "must not be a private network address",
        "https://[::1]/v1" => "must not be a private network address",
        "https://127.1/v1" => "must use a plain hostname or IP address",
        "https://2130706433/v1" => "must use a plain hostname or IP address",
        "https://169.254.169.254/" => "must not be a private network address",
        "not a url" => "is not a valid URL"
      }.each do |url, message|
        config = AiModelConfig.new(base_url: url)
        assert_not config.valid?, url
        assert_includes config.errors[:base_url], message, url
      end
    end

    should "allow a plain http local address in development only" do
      config = AiModelConfig.new(provider: "openai_compatible", base_url: "http://localhost:11434/v1", model: "llama3")

      assert_not config.valid?
      Rails.env.stub(:development?, true) { assert config.valid? }
    end
  end

  should "name the form's fields in errors, not the column names" do
    config = AiModelConfig.new(provider: "openai_compatible")
    config.valid?

    assert_no_match(/Base url/, config.errors.full_messages.join)
  end

  context "#normalized_base_url and #base_host" do
    should "strip whitespace and a trailing slash, and show only the host" do
      config = AiModelConfig.new(base_url: " https://ai-gateway.vercel.sh/v1/ ")

      assert_equal "https://ai-gateway.vercel.sh/v1", config.normalized_base_url
      assert_equal "ai-gateway.vercel.sh", config.base_host
      assert_nil AiModelConfig.new.base_host
      assert_nil AiModelConfig.new(base_url: "not a url").base_host
    end
  end

  context "#configured?" do
    should "need a valid config and a stored key" do
      assert_not AiModelConfig.new.configured?(build(:tenant))
      assert AiModelConfig.new.configured?(build(:tenant, :with_ai_model))
      assert_not AiModelConfig.new(provider: "openai_compatible").configured?(build(:tenant, :with_ai_model))
    end
  end

  context "the Vercel AI Gateway presets" do
    should "only fill the generic fields" do
      %w[vercel_ai_gateway vercel_ai_gateway_chat].each do |key|
        preset = AiModelConfig::PRESETS.fetch(key)

        assert_equal "https://ai-gateway.vercel.sh/v1", preset[:base_url]
        assert AiModelConfig.new(preset.slice(:provider, :base_url, :model)).valid?, key
      end
    end
  end
end
