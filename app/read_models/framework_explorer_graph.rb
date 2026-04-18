# frozen_string_literal: true

# Persistent snapshot of the Framework Explorer's view model. One row per
# framework; its `graph_data` is a plain JSON-encoded hash tree mirroring
# the structure of {Frameworks::ExplorerGraph::Framework}.
#
# Written by {Frameworks::ExplorerGraph.store} inside the same DB transaction
# as every framework event (see {Frameworks::Repository#with_framework}).
# Read by {Frameworks::ExplorerGraph.load}.
#
# JSON (not Marshal) — deserialization has no code-execution primitive, so a
# bug that let untrusted input reach this column would cost data integrity,
# not RCE.
#
# `format_version` is bumped whenever the serialized hash shape changes;
# stale rows are treated as missing so the controller falls back to a lazy
# {Frameworks::ExplorerGraph.rebuild} from the aggregate.
#
class FrameworkExplorerGraph < ApplicationRecord
  self.table_name = "framework_explorer_graphs"
  self.primary_key = "framework_id"

  validates :graph_data, presence: true
  validates :format_version, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
end
