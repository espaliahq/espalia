# frozen_string_literal: true

# Picks the adapter for a tenant's stored AI model. The one place that turns
# {AiModelConfig} and the encrypted key into a client, so callers never see
# which kind of endpoint answers.
#
# @example
#   Ai::ModelClient.for(tenant).suggest(system: framework, user: feedback, schema: schema)
module Ai::ModelClient
  module_function

  # @param tenant [Tenant]
  # @return [Boolean] whether {.for} can build a client: a complete endpoint
  #   and a key
  def configured?(tenant)
    tenant.effective_ai_config.configured?(tenant)
  end

  # @param tenant [Tenant]
  # @param model [String, nil] a model id to use in place of the configured
  #   one, for trying another model on the same endpoint
  # @return [Ai::Anthropic::Adapter, Ai::OpenAiCompatible::Adapter, Ai::TypesafeJev::Adapter]
  # @raise [ArgumentError] when the tenant has no usable config or key; check
  #   {.configured?} first
  def for(tenant, model: nil)
    config = tenant.effective_ai_config
    raise ArgumentError, "No AI model is configured for this workspace" unless config.configured?(tenant)

    model = model.presence || config.model
    case config.provider
    when "openai_compatible"
      Ai::OpenAiCompatible::Adapter.new(api_key: tenant.ai_api_key, base_url: config.normalized_base_url, model: model)
    when "typesafe_jev"
      Ai::TypesafeJev::Adapter.new(api_key: tenant.ai_api_key, base_url: config.normalized_base_url, model: model)
    else
      Ai::Anthropic::Adapter.new(api_key: tenant.ai_api_key, base_url: config.normalized_base_url, model: model,
                                 effort: config.effort)
    end
  end
end
