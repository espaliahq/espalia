# frozen_string_literal: true

# Ghost-entity predicates for the explorer's role tree.
#
# A role or role family is a **ghost** when it is not visible in the published
# framework view yet: role/family adds apply live (shape-preserving), but levels
# are draft-born (shape-changing), so a freshly-added role is structurally
# guaranteed to be hollow — no published levels, hence no matrix columns — until
# the next version is published. View mode hides ghosts (the published view
# stays clean); edit mode renders them with the wiggle, the explorer's universal
# "differs from published" signal (see SuggestionDecoration).
#
# The predicates are derived — no event, flag, or projection change: an
# ExplorerGraph level carries `added_in_draft`, and an AR read-model level is by
# construction published (the projection defers draft levels), so "no published
# level" is computable from either substrate. Ghost state self-clears at publish.
module Views::Frameworks::Explorer::Concerns::GhostEntities
  # @param role [FrameworkState::Role, Frameworks::ExplorerGraph::Role]
  # @return [Boolean] true when the role has at least one published level
  def published_role?(role)
    role.levels.any? { |level| !(level.respond_to?(:added_in_draft) && level.added_in_draft) }
  end

  # @param role [FrameworkState::Role, Frameworks::ExplorerGraph::Role]
  # @return [Boolean]
  def ghost_role?(role) = !published_role?(role)

  # @param role_family [FrameworkState::RoleFamily, Frameworks::ExplorerGraph::RoleFamily]
  # @return [Boolean] true when no role in the family has a published level
  def ghost_role_family?(role_family)
    role_family.roles.none? { |role| published_role?(role) }
  end

  # Tooltips conveying the ghost wiggle's meaning non-visually. Worded for the
  # ghost case specifically — unlike a draft-added entity, publishing alone
  # doesn't surface a level-less role.
  #
  # @return [String]
  def role_ghost_title
    "Not in the published framework yet — appears once it has published levels"
  end

  # @return [String]
  def role_family_ghost_title
    "Not in the published framework yet — appears once a role in it has published levels"
  end
end
