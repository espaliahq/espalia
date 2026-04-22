# frozen_string_literal: true

# Level node of the {Frameworks::ExplorerGraph}. `added_in_draft` means this
# level was created inside an open draft via `LevelAdded` and is not yet
# visible in the published view — view-mode rendering must hide it.
#
Frameworks::ExplorerGraph::Level = Data.define(
  :level_id,
  :role_id,
  :ordinal,
  :title,
  :code,
  :is_entry,
  :added_in_draft
) do
  def to_hash_tree
    {
      "level_id" => level_id,
      "role_id" => role_id,
      "ordinal" => ordinal,
      "title" => title,
      "code" => code,
      "is_entry" => is_entry,
      "added_in_draft" => added_in_draft
    }
  end

  def self.from_hash_tree(h)
    new(
      level_id: h["level_id"],
      role_id: h["role_id"],
      ordinal: h["ordinal"],
      title: h["title"],
      code: h["code"],
      is_entry: h["is_entry"],
      added_in_draft: h["added_in_draft"]
    )
  end
end
