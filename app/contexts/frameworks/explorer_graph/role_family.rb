# frozen_string_literal: true

# Role-family node of the {Frameworks::ExplorerGraph}. Shape-preserving —
# role families cannot be added in a draft in a way the explorer needs to
# hide, so there is no `added_in_draft` flag.
#
Frameworks::ExplorerGraph::RoleFamily = Data.define(
  :role_family_id,
  :name,
  :description,
  :department,
  :roles
)
