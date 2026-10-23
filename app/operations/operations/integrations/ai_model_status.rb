# frozen_string_literal: true

# Where this workspace's AI model stands.
#
# The read half of the AI model's MCP surface. The settings and the API key are
# edited on the Integrations page only, so no secret is ever exposed here:
# only whether a key is stored, and the host of the address, never the address
# itself.
class Operations::Integrations::AiModelStatus < Operations::Base
  description "Show how this workspace's AI model is set up for feedback placement suggestions: whether it is " \
              "ready (a complete provider, address and model with an API key stored; it does not prove the " \
              "endpoint answers), the provider, the host of its address, the model id, whether suggestions are " \
              "on, and whether a key is stored. Never returns the key. Names of people in the workspace are " \
              "always replaced with placeholders before feedback reaches the model."
  category :read
  approval :none

  def policy_check
    authorize :integrations, :show?
  end

  # @return [Hash]
  def perform
    tenant = ActsAsTenant.current_tenant
    config = tenant.effective_ai_config

    {
      state: config.state(tenant),
      configured: config.configured?(tenant),
      provider: config.provider,
      base_host: config.base_host,
      model: config.model.presence || (config.anthropic? ? AiModelConfig::DEFAULT_ANTHROPIC_MODEL : nil),
      effort: config.anthropic? ? config.effort : nil,
      suggestions_enabled: config.suggestions_enabled?,
      api_key_present: tenant.ai_api_key.present?
    }
  end
end
