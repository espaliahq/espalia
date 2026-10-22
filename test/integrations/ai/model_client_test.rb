# frozen_string_literal: true

require "test_helper"

class Ai::ModelClientTest < ActiveSupport::TestCase
  def gateway_tenant
    build(:tenant,
          ai_config: AiModelConfig.new(provider: "openai_compatible", base_url: "https://ai-gateway.vercel.sh/v1/", model: "anthropic/claude-opus-5-5"),
          ai_credentials: { "api_key" => "sk-gw" })
  end

  should "build the Anthropic adapter for an Anthropic tenant, with its effort and no address by default" do
    built = nil
    Ai::Anthropic::Adapter.stub(:new, ->(**options) { built = options; :adapter }) do
      tenant = build(:tenant, ai_config: AiModelConfig.new(model: "claude-haiku-5-5", effort: "high"), ai_credentials: { "api_key" => "sk-a" })

      assert_equal :adapter, Ai::ModelClient.for(tenant)
    end

    assert_equal({ api_key: "sk-a", base_url: nil, model: "claude-haiku-5-5", effort: "high" }, built)
  end

  should "build the OpenAI-compatible adapter for a gateway tenant" do
    adapter = Ai::ModelClient.for(gateway_tenant)

    assert_kind_of Ai::OpenAiCompatible::Adapter, adapter
    assert_equal "openai_compatible", adapter.provider
    assert_equal "anthropic/claude-opus-5-5", adapter.model
  end

  should "build the Jev adapter for a tenant on Jev" do
    tenant = build(:tenant, ai_config: AiModelConfig.new(provider: "typesafe_jev", base_url: "https://ai-gateway.vercel.sh/v1/",
                                                         model: "typesafe-ai/jev"),
                            ai_credentials: { "api_key" => "sk-gw" })
    adapter = Ai::ModelClient.for(tenant)

    assert_kind_of Ai::TypesafeJev::Adapter, adapter
    assert_equal [ "typesafe_jev", "typesafe-ai/jev" ], [ adapter.provider, adapter.model ]
  end

  should "pass an Anthropic-compatible address to the Anthropic adapter" do
    tenant = build(:tenant, ai_config: AiModelConfig.new(base_url: "https://proxy.example.com"), ai_credentials: { "api_key" => "sk-a" })
    adapter = Ai::ModelClient.for(tenant)

    assert_kind_of Ai::Anthropic::Adapter, adapter
    assert_equal "claude-opus-5-5", adapter.model
  end

  should "use the model the legacy setting named when the config has none" do
    tenant = build(:tenant, :with_ai_model, settings: { "evidence_suggestions_model" => "claude-haiku-5-5" })
    tenant.ai_config.model = nil

    assert_equal "claude-haiku-5-5", Ai::ModelClient.for(tenant).model
  end

  should "use a model override in place of the configured model" do
    assert_equal "openai/gpt-5", Ai::ModelClient.for(gateway_tenant, model: "openai/gpt-5").model
    assert_equal "anthropic/claude-opus-5-5", Ai::ModelClient.for(gateway_tenant, model: "").model
  end

  should "build nothing for a tenant with no key, or an incomplete endpoint" do
    assert_not Ai::ModelClient.configured?(build(:tenant))
    assert_raises(ArgumentError) { Ai::ModelClient.for(build(:tenant)) }

    incomplete = build(:tenant, ai_config: AiModelConfig.new(provider: "openai_compatible"), ai_credentials: { "api_key" => "sk-gw" })
    assert_not Ai::ModelClient.configured?(incomplete)
    assert_raises(ArgumentError) { Ai::ModelClient.for(incomplete) }
  end

  should "be configured for a complete endpoint with a key" do
    assert Ai::ModelClient.configured?(gateway_tenant)
    assert Ai::ModelClient.configured?(build(:tenant, :with_ai_model))
  end
end
