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
)
