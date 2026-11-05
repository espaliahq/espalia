# frozen_string_literal: true

# Typed decisions from TypeSafe AI's Jev, through Vercel's AI Gateway or any
# endpoint that serves `POST {base_url}/evaluate`.
#
# Jev is a decision model, not a chat model: it takes a shared state and named
# questions (`choice`, `score`, `boolean`) and answers each with probabilities,
# writing no prose. The request is `{ model, state, questions }`, each question
# `{ type, instructions, criteria }`, where a choice's criteria map option
# names to what each means; the answer is `{ model, answers, usage }`. See
# docs/guidelines/assessments/evidence.md for the shape as verified.
#
# @example
#   adapter = Ai::TypesafeJev::Adapter.new(api_key: key, base_url: "https://ai-gateway.vercel.sh/v1", model: "typesafe-ai/jev")
#   adapter.decide(state: { feedback: "…" }, questions: { valence: { type: "choice", instructions: "…", criteria: { … } } })
class Ai::TypesafeJev::Adapter
  include Ai::JsonEndpoint

  PING_STATE = "#{Rails.application.config.x.product_name} is checking that it can reach this model."
  PING_QUESTIONS = { reachable: { type: "boolean", instructions: "Is this a connection check?" } }.freeze

  # @param api_key [String]
  # @param base_url [String] the endpoint root, without /evaluate
  # @param model [String] e.g. "typesafe-ai/jev"
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
  def provider = "typesafe_jev"

  # @param state [String, Hash] what the questions are about
  # @param questions [Hash{Symbol => Hash}] name => { type:, instructions:, criteria: }
  # @return [Ai::DecisionResponse]
  # @raise [Ai::Errors::AuthenticationError, Ai::Errors::RateLimitError, Ai::Errors::ApiError] including
  #   a 200 that does not answer every question in the shape its type promises
  def decide(state:, questions:)
    body = post_json("evaluate", model: model, state: state, questions: questions)
    answers = body["answers"]
    unless answers.is_a?(Hash) && questions.all? { |name, question| valid_answer?(question, answers[name.to_s]) }
      raise Ai::Errors::ApiError.new(status: 200, body: body.to_json, message: "The model endpoint answered without every answer")
    end

    Ai::DecisionResponse.new(answers: answers, model: body["model"].presence || model, usage: usage_of(body))
  end

  # One trivial boolean question, to check the key, the address and the model id.
  #
  # @return [String] the answer, as words
  # @raise [Ai::Errors::AuthenticationError, Ai::Errors::RateLimitError, Ai::Errors::ApiError]
  def ping
    probability = decide(state: PING_STATE, questions: PING_QUESTIONS).answers.dig("reachable", "probability")
    return "" unless probability.is_a?(Numeric)

    "#{probability >= 0.5 ? 'yes' : 'no'}, #{(probability * 100).round}% sure this is a connection check"
  end

  private

  attr_reader :api_key, :base_url

  def valid_answer?(question, answer)
    return false unless answer.is_a?(Hash) && answer["type"] == question[:type].to_s

    case answer["type"]
    when "choice" then answer["choice"].present? && probabilities?(answer["probabilities"])
    when "score" then answer["score"].is_a?(Numeric) && probabilities?(answer["probabilities"])
    when "boolean" then answer["probability"].is_a?(Numeric)
    else false
    end
  end

  def probabilities?(raw) = raw.is_a?(Hash) && raw.any? && raw.values.all?(Numeric)

  # The gateway's HTTP API reports camelCase usage; TypeSafe's own API snake_case.
  def usage_of(body)
    usage = body["usage"].is_a?(Hash) ? body["usage"] : {}
    Ai::SuggestionResponse::Usage.new(input_tokens: usage["inputTokens"] || usage["input_tokens"],
                                      output_tokens: usage["outputTokens"] || usage["output_tokens"])
  end
end
