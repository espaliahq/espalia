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
)
