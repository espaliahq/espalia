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
# When the tenant keeps pseudonymisation on (the default), every person's name
# is swapped for a placeholder on the way out and swapped back in the rationales
# that come in. See {Ai::NamePseudonymiser}.
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

  # @return [String] "anthropic" or "openai_compatible", recorded on every row
  def provider = adapter.provider

  # @param prompt [Evidence::PlacementPrompt]
  # @return [Array<Proposal>] at most {MAX_SUGGESTIONS}, as the model ranked
  #   them; unvalidated against the framework (the caller does that)
  # @raise [RateLimited, Unavailable, Rejected]
  def suggest(prompt)
    names = pseudonymiser
    response = adapter.suggest(
      system: names ? names.pseudonymise(prompt.framework_text) : prompt.framework_text,
      user: names ? names.pseudonymise(prompt.item_text) : prompt.item_text,
      schema: prompt.schema
    )
    log(response)
    response.suggestions.first(MAX_SUGGESTIONS).map { |raw| proposal(raw, names) }
  rescue Ai::Errors::RateLimitError => e
    raise RateLimited, e.message
  rescue Ai::Errors::AuthenticationError => e
    raise Rejected, e.message
  rescue Ai::Errors::ApiError => e
    raise (e.status && (400..499).cover?(e.status) ? Rejected : Unavailable), e.message
  end

  private

  attr_reader :tenant

  def adapter
    @adapter ||= Ai::ModelClient.for(tenant)
  end

  def pseudonymiser
    Ai::NamePseudonymiser.for(tenant) if tenant.effective_ai_config.pseudonymise_names?
  end

  def log(response)
    Rails.logger.info(
      "[evidence-suggestions] #{provider} #{response.model}: #{response.suggestions.size} suggestions, " \
      "refused=#{response.refused?}, tokens in=#{response.usage.input_tokens} out=#{response.usage.output_tokens}"
    )
  end

  def proposal(raw, names)
    rationale = raw["rationale"].to_s.strip
    Proposal.new(
      capability_stable_id: raw["capability_stable_id"].to_s,
      level_ordinal: raw["level_ordinal"].to_i,
      valence: raw["valence"].to_s,
      confidence: raw["confidence"].to_f.clamp(0.0, 1.0),
      rationale: names ? names.restore(rationale) : rationale
    )
  end
end
