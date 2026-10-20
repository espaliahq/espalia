# frozen_string_literal: true

# Structured requests to the Anthropic API, or to any endpoint that speaks its
# Messages protocol, through the official gem.
#
# One instance holds one tenant's key, model and address; there is no global
# state, and the key is always passed to the gem explicitly, so an
# ANTHROPIC_API_KEY in the environment can never answer for a tenant.
#
# The system text is cached (`cache_control`), the schema goes in
# `output_config.format`, and thinking is left to the model: Opus 5.5 always
# thinks, and a budget or a disabled setting is rejected. No refusal fallback
# is sent; a refusal comes back as {Ai::SuggestionResponse#refused?}.
#
# @example
#   adapter = Ai::Anthropic::Adapter.new(api_key: key, model: "claude-opus-5-5")
#   adapter.suggest(system: framework, user: feedback, schema: schema)
class Ai::Anthropic::Adapter
  # Three short placements fit in a fraction of this; the rest is headroom
  # for thinking.
  MAX_TOKENS = 8_000
  PING_MAX_TOKENS = 1_000
  PING_PROMPT = "Reply with the single word: ready"
  TIMEOUT_SECONDS = 60

  # @param api_key [String]
  # @param model [String, nil] defaults to {AiModelConfig::DEFAULT_ANTHROPIC_MODEL}
  # @param base_url [String, nil] an Anthropic-compatible endpoint, without
  #   the /v1 the gem appends; nil for the Anthropic API itself
  # @param effort [String] one of {AiModelConfig::EFFORTS}
  # @param client [#messages, nil] injectable for tests
  def initialize(api_key:, model: nil, base_url: nil, effort: "low", client: nil)
    raise ArgumentError, "api_key is required" if api_key.blank?

    @api_key = api_key
    @model = model.presence || AiModelConfig::DEFAULT_ANTHROPIC_MODEL
    @base_url = base_url.presence
    @effort = effort.presence || "low"
    @client = client
  end

  attr_reader :model

  # @return [String]
  def provider = "anthropic"

  # @param system [String] the stable prefix, cached
  # @param user [String] the volatile tail
  # @param schema [Hash] a JSON schema the answer must match
  # @return [Ai::SuggestionResponse]
  # @raise [Ai::Errors::AuthenticationError, Ai::Errors::RateLimitError, Ai::Errors::ApiError]
  def suggest(system:, user:, schema:)
    message = request do
      client.messages.create(
        model: model,
        max_tokens: MAX_TOKENS,
        system_: [ { type: "text", text: system, cache_control: { type: "ephemeral" } } ],
        messages: [ { role: "user", content: user } ],
        output_config: { effort: @effort.to_sym, format_: { type: :json_schema, schema: schema } }
      )
    end
    response_from(message)
  end

  # One short request, to check the key, the address and the model id.
  #
  # @return [String] what the model said
  # @raise [Ai::Errors::RefusalError, Ai::Errors::AuthenticationError, Ai::Errors::RateLimitError, Ai::Errors::ApiError]
  def ping
    message = request do
      client.messages.create(model: model, max_tokens: PING_MAX_TOKENS, output_config: { effort: :low },
                             messages: [ { role: "user", content: PING_PROMPT } ])
    end
    raise Ai::Errors::RefusalError, "The model declined the test request" if message.stop_reason == :refusal

    text_of(message).strip
  end

  private

  # The job's retry_on is the one retry layer; the gem's own retries would
  # multiply every attempt during a rate-limit storm.
  def client
    @client ||= begin
      Ai::HostGuard.check!(@base_url) if @base_url
      ::Anthropic::Client.new(api_key: @api_key, base_url: @base_url, timeout: TIMEOUT_SECONDS, max_retries: 0)
    end
  end

  def request
    yield
  rescue ::Anthropic::Errors::AuthenticationError, ::Anthropic::Errors::PermissionDeniedError => e
    raise Ai::Errors::AuthenticationError, "The model endpoint rejected the API key (#{e.status})"
  rescue ::Anthropic::Errors::RateLimitError => e
    raise Ai::Errors::RateLimitError.new(retry_after: e.headers&.[]("retry-after")&.to_i)
  rescue ::Anthropic::Errors::APIStatusError => e
    raise Ai::Errors::ApiError.new(status: e.status, body: e.message)
  rescue ::Anthropic::Errors::APIConnectionError => e
    raise Ai::Errors::ApiError.new(status: nil, message: "Could not reach the model endpoint: #{e.class.name.demodulize}")
  end

  def response_from(message)
    stop_reason = message.stop_reason
    Rails.logger.info("[ai] no suggestions: stop_reason=#{stop_reason}") unless stop_reason == :end_turn

    Ai::SuggestionResponse.new(
      suggestions: stop_reason == :end_turn ? Ai::SuggestionResponse.suggestions_from(text_of(message)) : [],
      model: message.respond_to?(:model) ? message.model.to_s : model,
      usage: usage_of(message),
      refused: stop_reason == :refusal
    )
  end

  def text_of(message)
    message.content.select { |block| block.type == :text }.map(&:text).join
  end

  def usage_of(message)
    usage = message.respond_to?(:usage) ? message.usage : nil
    Ai::SuggestionResponse::Usage.new(input_tokens: usage&.input_tokens, output_tokens: usage&.output_tokens)
  end
end
