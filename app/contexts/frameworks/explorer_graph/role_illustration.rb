# frozen_string_literal: true

# Role-illustration node. Shape-preserving — `RoleIllustrationAdded` applies
# live to the published view, so illustrations are never individually
# draft-only. (An illustration attached to a draft-only capability is hidden
# because its ancestor expectation/capability is filtered out.)
#
Frameworks::ExplorerGraph::RoleIllustration = Data.define(
  :illustration_id,
  :stable_id,
  :expectation_id,
  :role_id,
  :ordinal,
  :description
)
