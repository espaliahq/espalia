# frozen_string_literal: true

# Role node of the {Frameworks::ExplorerGraph}. Shape-preserving — role adds
# apply live.
#
Frameworks::ExplorerGraph::Role = Data.define(
  :role_id,
  :role_family_id,
  :name,
  :code,
  :track,
  :levels
)
