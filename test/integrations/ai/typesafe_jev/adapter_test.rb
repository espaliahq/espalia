# frozen_string_literal: true

require "test_helper"

# The wire: what goes out to /evaluate and what comes back, in the shape
# Vercel's AI Gateway documents for decision models. Faraday's test adapter
# stands in for the endpoint; nothing here reaches the network.
class Ai::TypesafeJev::AdapterTest < ActiveSupport::TestCase
  BASE = "https://ai-gateway.vercel.sh/v1"
  MODEL = "typesafe-ai/jev"
  QUESTIONS = {
    placement: { type: "choice", instructions: "Which cell?", criteria: { "a|3" => "Ownership, level 3", "none" => "None" } },
    valence: { type: "choice", instructions: "Which valence?", criteria: { "demonstrated" => "shows it" } }
  }.freeze

  setup do
    @stubs = Faraday::Adapter::Test::Stubs.new
    connection = Faraday.new(url: "#{BASE}/") do |f|
      f.adapter :test, @stubs
      f.headers["Authorization"] = "Bearer sk-gw"
      f.headers["Content-Type"] = "application/json"
    end
    @adapter = Ai::TypesafeJev::Adapter.new(api_key: "sk-gw", base_url: "#{BASE}/", model: MODEL, connection: connection)
  end

  def json(body, status: 200, headers: {}) = [ status, { "Content-Type" => "application/json" }.merge(headers), body.to_json ]

  def answered
    { model: MODEL, usage: { inputTokens: 900, outputTokens: 20 },
      answers: {
        placement: { type: "choice", choice: "a|3", probabilities: { "a|3" => 0.7, "none" => 0.3 } },
        valence: { type: "choice", choice: "demonstrated", probabilities: { "demonstrated" => 1 } }
      } }
  end

  def decide = @adapter.decide(state: { framework: "f", feedback: "item" }, questions: QUESTIONS)

  should "post model, state and named questions to /evaluate with the bearer key" do
    body = headers = nil
    @stubs.post("/v1/evaluate") do |env|
      body = JSON.parse(env.body)
      headers = env.request_headers
      json(answered)
    end

    response = decide

    assert_equal "Bearer sk-gw", headers["Authorization"]
    assert_equal MODEL, body["model"]
    assert_equal({ "framework" => "f", "feedback" => "item" }, body["state"])
    assert_equal %w[placement valence], body["questions"].keys
    assert_equal({ "a|3" => "Ownership, level 3", "none" => "None" }, body.dig("questions", "placement", "criteria"))
    assert_equal "choice", body.dig("questions", "valence", "type")

    assert_equal({ "a|3" => 0.7, "none" => 0.3 }, response.probabilities(:placement))
    assert_equal "demonstrated", response.choice(:valence)
    assert_equal [ MODEL, 900, 20 ], [ response.model, response.usage.input_tokens, response.usage.output_tokens ]
  end

  should "treat a 200 that leaves a question unanswered as an endpoint error" do
    @stubs.post("/v1/evaluate") { json(answered.merge(answers: { placement: answered[:answers][:placement] })) }

    error = assert_raises(Ai::Errors::ApiError) { decide }
    assert_equal 200, error.status
  end

  should "map a refused key, a rate limit, a server error and no answer to the shared errors" do
    @stubs.post("/v1/evaluate") { json({ error: { message: "Authentication failed", type: "authentication_error" } }, status: 401) }
    assert_raises(Ai::Errors::AuthenticationError) { decide }

    @stubs = Faraday::Adapter::Test::Stubs.new
    adapter = ->(stubs) { Ai::TypesafeJev::Adapter.new(api_key: "k", base_url: BASE, model: MODEL, connection: Faraday.new(url: "#{BASE}/") { |f| f.adapter :test, stubs }) }
    limited = Faraday::Adapter::Test::Stubs.new { |s| s.post("/v1/evaluate") { json({}, status: 429, headers: { "Retry-After" => "12" }) } }
    assert_equal 12, assert_raises(Ai::Errors::RateLimitError) { adapter.(limited).decide(state: "s", questions: QUESTIONS) }.retry_after

    broken = Faraday::Adapter::Test::Stubs.new { |s| s.post("/v1/evaluate") { json({ error: { message: "boom" } }, status: 502) } }
    assert_equal 502, assert_raises(Ai::Errors::ApiError) { adapter.(broken).decide(state: "s", questions: QUESTIONS) }.status

    gone = Faraday::Adapter::Test::Stubs.new { |s| s.post("/v1/evaluate") { raise Faraday::ConnectionFailed, "refused" } }
    assert_nil assert_raises(Ai::Errors::ApiError) { adapter.(gone).decide(state: "s", questions: QUESTIONS) }.status
  end

  should "ping with one boolean question and report the answer in words" do
    sent = nil
    @stubs.post("/v1/evaluate") do |env|
      sent = JSON.parse(env.body)
      json({ model: MODEL, answers: { reachable: { type: "boolean", probability: 0.97 } }, usage: {} })
    end

    assert_equal "yes, 97% sure this is a connection check", @adapter.ping
    assert_equal "boolean", sent.dig("questions", "reachable", "type")
    assert_kind_of String, sent["state"]
  end

  should "refuse a private address before sending anything" do
    adapter = Ai::TypesafeJev::Adapter.new(api_key: "k", base_url: "https://10.0.0.5/v1", model: MODEL)

    assert_raises(Ai::Errors::ConfigurationError) { adapter.ping }
  end

  should "need a key, an address and a model" do
    assert_raises(ArgumentError) { Ai::TypesafeJev::Adapter.new(api_key: "", base_url: BASE, model: MODEL) }
    assert_raises(ArgumentError) { Ai::TypesafeJev::Adapter.new(api_key: "k", base_url: nil, model: MODEL) }
    assert_raises(ArgumentError) { Ai::TypesafeJev::Adapter.new(api_key: "k", base_url: BASE, model: "") }
  end
end
