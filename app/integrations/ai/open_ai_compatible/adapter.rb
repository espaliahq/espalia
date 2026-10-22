# frozen_string_literal: true

# Structured requests to any endpoint that serves `POST {base_url}/chat/completions`:
# Vercel's AI Gateway, OpenAI, a self-hosted server, a proxy. Nothing here knows
# which; the gateway is only a base URL and a model id such as
# `anthropic/claude-opus-5-5`.
#
# The schema goes in `response_format` as a strict `json_schema`, the key as a
# bearer token. The answer is parsed, not trusted: the caller re-checks every
# value against the candidates it offered.
#
# @example
#   adapter = Ai::OpenAiCompatible::Adapter.new(
#     api_key: key, base_url: "https://ai-gateway.vercel.sh/v1", model: "anthropic/claude-opus-5-5"
#   )
#   adapter.suggest(system: framework, user: feedback, schema: schema)
class Ai::OpenAiCompatible::Adapter
  include Ai::JsonEndpoint

  MAX_TOKENS = 8_000
  PING_MAX_TOKENS = 1_000
  PING_PROMPT = "Reply with the single word: ready"
  SCHEMA_NAME = "placement_suggestions"
  # OpenAI deprecated max_tokens and its reasoning models reject it; most other
  # servers (the gateway, vLLM, Ollama) only know max_tokens. Models named for
  # OpenAI's reasoning families, or served from api.openai.com, get the new name.
  OPENAI_REASONING_MODEL = %r{\A(?:openai/)?(?:o\d|gpt-5)}i

  # @param api_key [String]
  # @param base_url [String] the endpoint root, without /chat/completions
  # @param model [String] the endpoint's model id
  # @param connection [Faraday::Connection, nil] injectable for tests
  def initialize(api_key:, base_url:, model:, connection: nil)
    raise ArgumentError, "api_key is required" if api_key.blank?
    raise ArgumentError, "base_url is required" if base_url.blank?
    raise ArgumentError, "model is required" if model.blank?

    @api_key = api_key
    @base_url = base_url.to_s.strip.chomp("/")
    @model = model
    @connection = connection
  end

  attr_reader :model

  # @return [String]
  def provider = "openai_compatible"

  # @param system [String]
  # @param user [String]
  # @param schema [Hash] a JSON schema the answer must match
  # @return [Ai::SuggestionResponse]
  # @raise [Ai::Errors::AuthenticationError, Ai::Errors::RateLimitError, Ai::Errors::ApiError]
  def suggest(system:, user:, schema:)
    body = post_json(
      "chat/completions",
      model: model, **token_limit(MAX_TOKENS),
      messages: [ { role: "system", content: system }, { role: "user", content: user } ],
      response_format: { type: "json_schema", json_schema: { name: SCHEMA_NAME, strict: true, schema: schema } }
    )
    choice = first_choice(body)
    refused = refused?(choice)
    finished = choice["finish_reason"] == "stop"
    Rails.logger.info("[ai] no suggestions: finish_reason=#{choice['finish_reason']}") unless finished

    Ai::SuggestionResponse.new(
      suggestions: finished && !refused ? Ai::SuggestionResponse.suggestions_from(content_text(choice)) : [],
      model: body["model"].presence || model,
      usage: usage_of(body),
      refused: refused
    )
  end

  # One short request, to check the key, the address and the model id.
  #
  # @return [String] what the model said
  # @raise [Ai::Errors::RefusalError, Ai::Errors::AuthenticationError, Ai::Errors::RateLimitError, Ai::Errors::ApiError]
  def ping
    body = post_json("chat/completions", model: model, **token_limit(PING_MAX_TOKENS), messages: [ { role: "user", content: PING_PROMPT } ])
    choice = first_choice(body)
    raise Ai::Errors::RefusalError, "The model declined the test request" if refused?(choice)

    content_text(choice).strip
  end

  private

  attr_reader :api_key, :base_url

  def token_limit(tokens)
    openai_style = base_url.match?(%r{\Ahttps://api\.openai\.com(?:/|\z)}i) || model.match?(OPENAI_REASONING_MODEL)
    { (openai_style ? :max_completion_tokens : :max_tokens) => tokens }
  end

  def first_choice(body)
    choice = body["choices"]&.first
    return choice if choice.is_a?(Hash) && choice["message"].is_a?(Hash)

    raise Ai::Errors::ApiError.new(status: 200, body: body.to_json, message: "The model endpoint answered without a choice")
  end

  # Some servers answer with the message content as a list of parts, each
  # `{ "type" => "text", "text" => … }`, instead of one string.
  def content_text(choice)
    content = choice.dig("message", "content")
    return content.to_s unless content.is_a?(Array)

    content.filter_map { |part| part["text"] if part.is_a?(Hash) && part["text"].is_a?(String) }.join
  end

  def refused?(choice)
    choice.dig("message", "refusal").present? || choice["finish_reason"] == "content_filter"
  end

  def usage_of(body)
    usage = body["usage"].is_a?(Hash) ? body["usage"] : {}
    Ai::SuggestionResponse::Usage.new(input_tokens: usage["prompt_tokens"], output_tokens: usage["completion_tokens"])
  end
end
