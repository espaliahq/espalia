# frozen_string_literal: true

# A placement asked of a decision model (TypeSafe AI's Jev) rather than a chat
# model: the same framework and feedback as the chat prompt, as the shared
# state, and two choice questions about it, answered in one request.
#
# - `placement`: one option per open cell, named "<capability_stable_id>|<level_ordinal>"
#   (the token the evidence form uses), plus `none` for feedback the framework
#   does not cover, so the probability has somewhere to go when no cell fits.
# - `valence`: the four valences, read from the feedback as a whole.
#
# Jev answers every question independently against the state, so the valence
# cannot be asked of the chosen cell in the same request. One reading per item
# is the trade: a piece of feedback rarely praises one behaviour and faults
# another, and a second request would double the latency and cost of every run.
#
# The cells come back ranked by probability; those under {FLOOR} are dropped,
# and the probability is the confidence. Jev writes no rationale.
class Evidence::PlacementDecision
  # Recorded on every row in place of {Evidence::PlacementPrompt::VERSION}.
  # Bump it whenever the questions or the state change.
  VERSION = "jev-2026-10-21.1"
  FLOOR = 0.15
  NONE = "none"

  # @param prompt [Evidence::PlacementPrompt]
  # @param names [Ai::NamePseudonymiser, nil] hides people's names in what is sent
  def initialize(prompt, names: nil)
    @prompt = prompt
    @names = names
  end

  # @return [Hash] the framework (full names hidden) and the feedback (every
  #   name hidden), as the chat path hides them
  def state
    { framework: hide(prompt.framework_description, first_names: false), feedback: hide(prompt.item_text) }
  end

  # @return [Hash{Symbol => Hash}]
  def questions
    {
      placement: {
        type: "choice",
        instructions: "Which capability and level of the framework is this feedback evidence about? Choose the cell " \
                      "whose behavioural expectation the feedback speaks to. Prefer the person's own level, " \
                      "#{prompt.home_ordinal}, unless the feedback clearly describes behaviour expected at the level " \
                      "above or below. Choose #{NONE} when the feedback says nothing these expectations cover.",
        criteria: cell_criteria.merge(NONE => "The feedback says nothing any of these expectations covers.")
      },
      valence: {
        type: "choice",
        instructions: "What does the feedback say about the behaviour it describes?",
        criteria: Evidence::PlacementPrompt::VALENCE_MEANINGS
      }
    }
  end

  # @param response [Ai::DecisionResponse]
  # @param limit [Integer]
  # @return [Array<Evidence::SuggestionModel::Proposal>] most probable first
  def proposals(response, limit:)
    valence = response.choice(:valence)
    response.probabilities(:placement)
      .select { |option, probability| probability >= FLOOR && prompt.open_cells.key?(option) }
      .first(limit)
      .map do |option, probability|
        stable_id, ordinal = option.split("|")
        Evidence::SuggestionModel::Proposal.new(capability_stable_id: stable_id, level_ordinal: ordinal.to_i,
                                                valence: valence.to_s, confidence: probability, rationale: nil)
      end
  end

  private

  attr_reader :prompt, :names

  def cell_criteria
    prompt.open_cells.transform_values do |cell|
      hide("#{cell[:capability_name]}, level #{cell[:level_ordinal]}: #{cell[:expectation]}", first_names: false)
    end
  end

  def hide(text, first_names: true)
    names ? names.pseudonymise(text, first_names: first_names) : text
  end
end
