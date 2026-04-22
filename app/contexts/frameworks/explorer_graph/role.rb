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
) do
  def to_hash_tree
    {
      "role_id" => role_id,
      "role_family_id" => role_family_id,
      "name" => name,
      "code" => code,
      "track" => track,
      "levels" => levels.map(&:to_hash_tree)
    }
  end

  def self.from_hash_tree(h)
    new(
      role_id: h["role_id"],
      role_family_id: h["role_family_id"],
      name: h["name"],
      code: h["code"],
      track: h["track"],
      levels: h.fetch("levels", []).map { |x| Frameworks::ExplorerGraph::Level.from_hash_tree(x) }
    )
  end
end
