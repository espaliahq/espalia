# frozen_string_literal: true

# What an adapter hands back for a structured request: the model's answer
# parsed, and enough about the call to record and audit it. Both adapters
# return this one shape, so nothing above them knows which kind of endpoint
# answered.
#
# @!attribute suggestions
#   @return [Array<Hash>] the `suggestions` array the model returned, as parsed
#     JSON and unvalidated; empty when it refused, ran out of tokens or
#     answered with something unparseable
# @!attribute model
#   @return [String] the model id the endpoint reports having used
# @!attribute usage
#   @return [Usage]
# @!attribute refused
#   @return [Boolean] whether the model declined to answer
class Ai::SuggestionResponse < Data.define(:suggestions, :model, :usage, :refused)
  Usage = Data.define(:input_tokens, :output_tokens)

  # @return [Boolean]
  def refused? = refused

  # Pulls the `suggestions` array out of the model's JSON text. Text that is
  # not JSON, or not an object with an array, is no suggestions: a model that
  # rambles has not failed the request.
  #
  # @param text [String, nil]
  # @return [Array<Hash>]
  def self.suggestions_from(text)
    return [] unless text.is_a?(String) && text.present?

    parsed = JSON.parse(text)
    list = parsed.is_a?(Hash) ? parsed["suggestions"] : nil
    list.is_a?(Array) ? list.grep(Hash) : []
  rescue JSON::ParserError
    []
  end
end
