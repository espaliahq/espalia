# frozen_string_literal: true

# The one place GrowthOS asks a model where feedback belongs: given a placement
# prompt, return the placements the model proposes. Which model answers is the
# tenant's choice ({AiModelConfig}); {Ai::ModelClient} picks the adapter, and
# nothing here knows which kind it is. Everything else — which cells exist,
# what gets stored — is the caller's; tests stub {#suggest} and never an adapter.
#
# Failures come back as this class's own errors so the job can choose a retry
# policy without knowing the adapter: {RateLimited} and {Unavailable} are worth
# retrying, {Rejected} is not. A refusal, a truncated answer or an unparseable
# one is "no suggestions", never an error.
#
# A chat model answers with structured JSON; a decision model (Jev) with
# probabilities over the candidate cells, read by {Evidence::PlacementDecision}.
#
# When the tenant keeps pseudonymisation on (the default), every person's name
# is swapped for a placeholder on the way out and swapped back in the rationales
# that come in. See {Ai::NamePseudonymiser}. The framework text gets full names
# only: it is about the framework, not a person, and a first name that is an
# ordinary word (Will, Mark) would only damage it.
class Evidence::SuggestionModel
  MAX_SUGGESTIONS = 3

  Proposal = Data.define(:capability_stable_id, :level_ordinal, :valence, :confidence, :rationale)

  class Error < StandardError; end
  # 429: back off and try again.
  class RateLimited < Error; end
  # 5xx, timeouts, a dropped connection: try again.
  class Unavailable < Error; end
  # The key was refused, or any other 4xx: the request itself is wrong;
  # retrying sends the same thing.
  class Rejected < Error; end

  # @param tenant [Tenant]
  # @return [Boolean] whether the tenant has a complete model config and a key
  def self.configured?(tenant)
    Ai::ModelClient.configured?(tenant)
  end

  # @param tenant [Tenant]
  # @param adapter [#suggest, nil] injectable for tests
  def initialize(tenant:, adapter: nil)
    @tenant = tenant
    @adapter = adapter
  end

  # @return [String] the configured model id, recorded on every row
  def model = adapter.model

  # @return [String] one of {AiModelConfig::PROVIDERS}, recorded on every row
  def provider = adapter.provider

  # @return [String] the version of what was asked, recorded on every row
  def prompt_version = decision_model? ? Evidence::PlacementDecision::VERSION : Evidence::PlacementPrompt::VERSION

  # @param prompt [Evidence::PlacementPrompt]
  # @return [Array<Proposal>] at most {MAX_SUGGESTIONS}, as the model ranked
  #   them; unvalidated against the framework (the caller does that)
  # @raise [RateLimited, Unavailable, Rejected]
  def suggest(prompt)
    decision_model? ? decide(prompt, pseudonymiser) : chat(prompt, pseudonymiser)
  rescue Ai::Errors::RateLimitError => e
    raise RateLimited, e.message
  rescue Ai::Errors::AuthenticationError, Ai::Errors::ConfigurationError => e
    raise Rejected, e.message
  rescue Ai::Errors::ApiError => e
    raise (permanent?(e) ? Rejected : Unavailable), e.message
  end

  private

  # A 4xx says the request itself is wrong, except 408, which says only that
  # the endpoint was too slow. No status, a 5xx or an answer that was not an
  # answer (status 200) might be gone in a minute.
  def permanent?(error)
    error.status.present? && (400..499).cover?(error.status) && error.status != 408
  end

  attr_reader :tenant

  def decision_model? = adapter.respond_to?(:decide)

  def chat(prompt, names)
    response = adapter.suggest(
      system: names ? names.pseudonymise(prompt.framework_text, first_names: false) : prompt.framework_text,
      user: names ? names.pseudonymise(prompt.item_text) : prompt.item_text,
      schema: prompt.schema
    )
    log(response, response.suggestions.size, refused: response.refused?)
    response.suggestions.first(MAX_SUGGESTIONS).map { |raw| proposal(raw, names) }
  end

  # A decision model answers typed questions with probabilities, not prose:
  # see {Evidence::PlacementDecision}.
  def decide(prompt, names)
    decision = Evidence::PlacementDecision.new(prompt, names: names)
    response = adapter.decide(state: decision.state, questions: decision.questions)
    proposals = decision.proposals(response, limit: MAX_SUGGESTIONS)
    log(response, proposals.size)
    proposals
  end

  def adapter
    @adapter ||= Ai::ModelClient.for(tenant)
  end

  def pseudonymiser
    Ai::NamePseudonymiser.for(tenant) if tenant.effective_ai_config.pseudonymise_names?
  end

  def log(response, count, refused: false)
    Rails.logger.info(
      "[evidence-suggestions] #{provider} #{response.model}: #{count} suggestions, " \
      "refused=#{refused}, tokens in=#{response.usage.input_tokens} out=#{response.usage.output_tokens}"
    )
  end

  def proposal(raw, names)
    rationale = raw["rationale"].to_s.strip.presence
    Proposal.new(
      capability_stable_id: raw["capability_stable_id"].to_s,
      level_ordinal: raw["level_ordinal"].to_i,
      valence: raw["valence"].to_s,
      confidence: raw["confidence"].to_f.clamp(0.0, 1.0),
      rationale: names && rationale ? names.restore(rationale) : rationale
    )
  end
end
