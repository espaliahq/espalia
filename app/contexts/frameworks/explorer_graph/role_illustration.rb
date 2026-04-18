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
) do
  def to_hash_tree
    {
      "illustration_id" => illustration_id,
      "stable_id" => stable_id,
      "expectation_id" => expectation_id,
      "role_id" => role_id,
      "ordinal" => ordinal,
      "description" => description
    }
  end

  def self.from_hash_tree(h)
    new(
      illustration_id: h["illustration_id"],
      stable_id: h["stable_id"],
      expectation_id: h["expectation_id"],
      role_id: h["role_id"],
      ordinal: h["ordinal"],
      description: h["description"]
    )
  end
end
