# frozen_string_literal: true

# Behavioural-expectation node. `added_in_draft` means the expectation was
# set via `BehaviouralExpectationSet` inside an open draft and is not yet
# published. The builder only sets this when the *expectation itself* was
# added during the draft — expectations hanging off a draft-only capability
# are naturally hidden because their parent is filtered out.
#
Frameworks::ExplorerGraph::BehaviouralExpectation = Data.define(
  :expectation_id,
  :stable_id,
  :capability_id,
  :level_ordinal,
  :description,
  :illustrations,
  :added_in_draft
) do
  def to_hash_tree
    {
      "expectation_id" => expectation_id,
      "stable_id" => stable_id,
      "capability_id" => capability_id,
      "level_ordinal" => level_ordinal,
      "description" => description,
      "illustrations" => illustrations.map(&:to_hash_tree),
      "added_in_draft" => added_in_draft
    }
  end

  def self.from_hash_tree(h)
    new(
      expectation_id: h["expectation_id"],
      stable_id: h["stable_id"],
      capability_id: h["capability_id"],
      level_ordinal: h["level_ordinal"],
      description: h["description"],
      illustrations: h.fetch("illustrations", []).map { |x| Frameworks::ExplorerGraph::RoleIllustration.from_hash_tree(x) },
      added_in_draft: h["added_in_draft"]
    )
  end
end
