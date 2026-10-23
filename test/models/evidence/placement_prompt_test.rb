# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

class Evidence::PlacementPromptTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  setup { build_placement_fixture }
  teardown { ActsAsTenant.current_tenant = nil }

  def prompt_for(item) = ActsAsTenant.with_tenant(@tenant) { Evidence::PlacementPrompt.new(item).tap(&:cells) }

  should "offer only the cells the recipient's role reads, at their level and one either side" do
    prompt = prompt_for(record_peer_feedback)

    expected = [ @ownership, @collaboration ].product([ 2, 3, 4 ]).map { |cap, level| "#{cap.stable_id}|#{level}" }
    assert_equal expected.sort, prompt.cells.keys.sort
    assert_not prompt.open_cell?(@ownership.stable_id, 5), "level 5 is outside the window"
    assert_not prompt.open_cell?(@design_craft.stable_id, 3), "another role's capability is not a candidate"
  end

  should "carry the capability description, the expectation and up to three examples per cell" do
    cell = prompt_for(record_peer_feedback).cells["#{@ownership.stable_id}|3"]

    assert_equal "Sees work through.", cell[:capability_description]
    assert_equal "Ownership at 3", cell[:expectation]
    assert_equal [ "Ownership example at 3" ], cell[:illustrations]
  end

  should "close the cells an item is already linked to, and say so in the request" do
    prompt = prompt_for(record_peer_feedback(placed_on: @ownership))

    assert_not prompt.open_cell?(@ownership.stable_id, 3)
    assert prompt.open_cell?(@ownership.stable_id, 4)
    assert_includes prompt.item_text, "Already placed at"
  end

  should "close a cell someone dismissed for this item" do
    item = record_peer_feedback
    ActsAsTenant.with_tenant(@tenant) do
      create(:evidence_placement_suggestion, tenant: @tenant, item: item,
        capability_stable_id: @collaboration.stable_id, level_ordinal: 3, status: "dismissed")
    end

    assert_not prompt_for(item).open_cell?(@collaboration.stable_id, 3)
  end

  should "keep the framework text the same for two items at the same role and level" do
    first = prompt_for(record_peer_feedback(content: "One."))
    second = prompt_for(record_peer_feedback(content: "Two.", placed_on: @collaboration))

    assert_equal first.framework_text, second.framework_text
    assert_includes first.item_text, "One."
    assert_includes first.item_text, "a peer"
  end

  should "name the person themselves as the giver of self feedback, with or without a recorded direction" do
    item = record_self_feedback
    assert_includes prompt_for(item).item_text, "Feedback from the person themselves"

    ActsAsTenant.with_tenant(@tenant) { item.update_columns(feedback_direction: nil) }
    assert_includes prompt_for(item.reload).item_text, "Feedback from the person themselves"
  end

  should "limit the schema's ids and levels to the candidates" do
    schema = prompt_for(record_peer_feedback).schema
    item_props = schema.dig(:properties, :suggestions, :items, :properties)

    assert_equal [ @ownership.stable_id, @collaboration.stable_id ].sort, item_props[:capability_stable_id][:enum]
    assert_equal [ 2, 3, 4 ], item_props[:level_ordinal][:enum]
    assert_equal EvidenceLink::VALENCES, item_props[:valence][:enum]
  end
end
