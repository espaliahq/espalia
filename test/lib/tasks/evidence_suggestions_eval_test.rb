# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/tasks/evidence_suggestions_eval")

# The eval itself calls the API and is not run in CI. This keeps its plumbing
# and fixtures honest with the word-overlap baseline, which needs no API.
class EvidenceSuggestionsEvalTest < ActiveSupport::TestCase
  should "score every fixture and leave nothing behind" do
    report = EvidenceSuggestionsEval.new(model: EvidenceSuggestionsEval::BaselineModel.new).run

    assert_equal 30, report[:items]
    assert_equal [ 27, 3 ], [ report[:placeable], report[:uncovered] ]
    assert_equal Evidence::PlacementPrompt::VERSION, report[:prompt_version]
    assert_operator report[:cell_match_top], :>, 0
    assert_not Tenant.exists?([ "slug LIKE ?", "suggestion-eval-%" ])
  end
end
