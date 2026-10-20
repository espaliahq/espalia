# frozen_string_literal: true

# The one place GrowthOS calls Claude: given a placement prompt, return the
# placements the model proposes. Everything else — which cells exist, what
# gets stored — is the caller's; tests stub {#suggest} and never the gem.
#
# Failures come back as this class's own errors so the job can choose a
# retry policy without knowing the SDK: {RateLimited} and {Unavailable} are
# worth retrying, {Rejected} is not. A refusal, a truncated answer or an
# unparseable one is "no suggestions", never an error.
class Evidence::SuggestionModel
  DEFAULT_MODEL = "claude-opus-5-5"
  # Three short placements fit in a fraction of this; the rest is headroom
  # for thinking, which Opus 5.5 always does at some depth.
  MAX_TOKENS = 8_000
  TIMEOUT_SECONDS = 60
  MAX_SUGGESTIONS = 3

  Proposal = Data.define(:capability_stable_id, :level_ordinal, :valence, :confidence, :rationale)

  class Error < StandardError; end
  # 429: back off and try again.
  class RateLimited < Error; end
  # 5xx, timeouts, a dropped connection: try again.
  class Unavailable < Error; end
  # Any other 4xx: the request itself is wrong; retrying sends the same thing.
  class Rejected < Error; end

  # @return [Boolean] whether an API key is configured
  def self.configured?
    api_key.present?
  end

  def self.api_key
    Rails.application.credentials.dig(:anthropic, :api_key)
  end

  # @param model [String] the Claude model id
  def initialize(model: DEFAULT_MODEL)
    @model = model.presence || DEFAULT_MODEL
  end

  attr_reader :model

  # @param prompt [Evidence::PlacementPrompt]
  # @return [Array<Proposal>] at most {MAX_SUGGESTIONS}, as the model ranked
  #   them; unvalidated against the framework (the caller does that)
  # @raise [RateLimited, Unavailable, Rejected]
  def suggest(prompt)
    message = client.messages.create(
      model: model,
      max_tokens: MAX_TOKENS,
      system_: [ { type: "text", text: prompt.framework_text, cache_control: { type: "ephemeral" } } ],
      messages: [ { role: "user", content: prompt.item_text } ],
      output_config: { effort: :low, format_: { type: :json_schema, schema: prompt.schema } }
    )
    proposals_from(message)
  rescue Anthropic::Errors::RateLimitError => e
    raise RateLimited, e.message
  rescue Anthropic::Errors::InternalServerError, Anthropic::Errors::APIConnectionError => e
    raise Unavailable, e.message
  rescue Anthropic::Errors::APIStatusError => e
    raise Rejected, "#{e.status}: #{e.message}"
  end

  private

  # The job's retry_on is the one retry layer; the SDK's own retries would
  # multiply every attempt during a rate-limit storm.
  def client
    @client ||= Anthropic::Client.new(api_key: self.class.api_key, timeout: TIMEOUT_SECONDS, max_retries: 0)
  end

  def proposals_from(message)
    unless message.stop_reason == :end_turn
      Rails.logger.info("[evidence-suggestions] no suggestions: stop_reason=#{message.stop_reason}")
      return []
    end

    text = message.content.find { |block| block.type == :text }&.text
    return [] if text.blank?

    Array(JSON.parse(text)["suggestions"]).first(MAX_SUGGESTIONS).filter_map { |raw| proposal(raw) }
  rescue JSON::ParserError
    []
  end

  def proposal(raw)
    return nil unless raw.is_a?(Hash)

    Proposal.new(
      capability_stable_id: raw["capability_stable_id"].to_s,
      level_ordinal: raw["level_ordinal"].to_i,
      valence: raw["valence"].to_s,
      confidence: raw["confidence"].to_f.clamp(0.0, 1.0),
      rationale: raw["rationale"].to_s.strip
    )
  end
end
