# frozen_string_literal: true

# What a decision model hands back: one answer per question asked, keyed by
# the question's name, plus enough about the call to log it.
#
# A choice answer is `{ "type" => "choice", "choice" => "<option>",
# "probabilities" => { "<option>" => 0.0..1.0 } }`; a boolean answer is
# `{ "type" => "boolean", "probability" => 0.0..1.0 }`.
#
# @!attribute answers
#   @return [Hash{String => Hash}]
# @!attribute model
#   @return [String] the model id the endpoint reports having used
# @!attribute usage
#   @return [Ai::SuggestionResponse::Usage]
class Ai::DecisionResponse < Data.define(:answers, :model, :usage)
  # @param name [String, Symbol] a question's name
  # @return [Hash{String => Float}] each option's probability, highest first;
  #   empty when the answer carries none
  def probabilities(name)
    raw = answers.dig(name.to_s, "probabilities")
    return {} unless raw.is_a?(Hash)

    raw.filter_map { |option, p| [ option.to_s, p.to_f.clamp(0.0, 1.0) ] if p.is_a?(Numeric) }
       .sort_by { |_, p| -p }.to_h
  end

  # @param name [String, Symbol] a choice question's name
  # @return [String, nil] the option the model chose, or the likeliest one
  def choice(name)
    answers.dig(name.to_s, "choice").presence&.to_s || probabilities(name).keys.first
  end
end
