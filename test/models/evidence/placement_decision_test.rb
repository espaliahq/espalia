# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

# What a decision model is asked about a piece of feedback, and how its
# probabilities become suggestions.
class Evidence::PlacementDecisionTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  setup { build_placement_fixture }

  def decision_for(item, names: nil)
    ActsAsTenant.with_tenant(@tenant) { Evidence::PlacementDecision.new(Evidence::PlacementPrompt.new(item).tap(&:open_cells), names: names) }
  end

  def response(placement, valence: "demonstrated")
    Ai::DecisionResponse.new(
      answers: { "placement" => { "type" => "choice", "choice" => placement.max_by(&:last)&.first, "probabilities" => placement },
                 "valence" => { "type" => "choice", "choice" => valence, "probabilities" => { valence => 0.9 } } },
      model: "typesafe-ai/jev", usage: Ai::SuggestionResponse::Usage.new(input_tokens: 1, output_tokens: 1)
    )
  end

  def token(capability, level) = "#{capability.stable_id}|#{level}"

  should "offer every open cell and none as the placement options, and the four valences" do
    item = record_peer_feedback(placed_on: @ownership)
    questions = decision_for(item).questions

    expected = [ @ownership, @collaboration ].product([ 2, 3, 4 ]).map { |cap, level| token(cap, level) } - [ token(@ownership, 3) ]
    assert_equal (expected + [ "none" ]).sort, questions.dig(:placement, :criteria).keys.sort
    assert_equal "Ownership, level 4: Ownership at 4", questions.dig(:placement, :criteria, token(@ownership, 4))
    assert_includes questions.dig(:placement, :instructions), "own level, 3"
    assert_equal EvidenceLink::VALENCES.sort, questions.dig(:valence, :criteria).keys.sort
    assert_equal %w[choice choice], questions.values.map { |q| q[:type] }
  end

  should "send the framework without the chat instructions, and the feedback, as the state" do
    state = decision_for(record_peer_feedback).state

    assert state[:framework].start_with?("Framework: the Software Engineer role")
    assert_not_includes state[:framework], "rationale"
    assert_includes state[:feedback], "owned the outage follow-up"
  end

  should "hide names in the state and the options, as the chat path does" do
    item = record_peer_feedback
    names = ActsAsTenant.with_tenant(@tenant) { Ai::NamePseudonymiser.for(@tenant) }
    decision = decision_for(item, names: names)

    sent = [ decision.state, decision.questions ].to_json
    assert_no_match(/Alex|Jordan|Morgan/, sent)
    assert_match(/Person \d+ owned the outage/, decision.state[:feedback])
  end

  should "rank the cells by probability, drop those under the floor and none, and read one valence for them all" do
    decision = decision_for(record_peer_feedback)
    proposals = decision.proposals(
      response({ token(@ownership, 3) => 0.55, "none" => 0.2, token(@collaboration, 3) => 0.16,
                 token(@ownership, 4) => 0.05, "#{SecureRandom.uuid_v7}|3" => 0.4 }, valence: "growth_area"),
      limit: 3
    )

    assert_equal [ [ @ownership.stable_id, 3 ], [ @collaboration.stable_id, 3 ] ], proposals.map { |p| [ p.capability_stable_id, p.level_ordinal ] }
    assert_equal [ 0.55, 0.16 ], proposals.map(&:confidence)
    assert_equal %w[growth_area growth_area], proposals.map(&:valence)
    assert proposals.all? { |p| p.rationale.nil? }
  end

  should "suggest nothing when none takes the probability" do
    proposals = decision_for(record_peer_feedback).proposals(response({ "none" => 0.9, token(@ownership, 3) => 0.1 }), limit: 3)

    assert_empty proposals
  end

  should "keep to the limit" do
    probabilities = [ 2, 3, 4 ].to_h { |level| [ token(@ownership, level), 0.3 ] }
    assert_equal 2, decision_for(record_peer_feedback).proposals(response(probabilities), limit: 2).size
  end
end
