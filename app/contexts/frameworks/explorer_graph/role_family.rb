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
) do
  def to_hash_tree
    {
      "role_family_id" => role_family_id,
      "name" => name,
      "description" => description,
      "department" => department,
      "roles" => roles.map(&:to_hash_tree)
    }
  end

  def self.from_hash_tree(h)
    new(
      role_family_id: h["role_family_id"],
      name: h["name"],
      description: h["description"],
      department: h["department"],
      roles: h.fetch("roles", []).map { |x| Frameworks::ExplorerGraph::Role.from_hash_tree(x) }
    )
  end
end
