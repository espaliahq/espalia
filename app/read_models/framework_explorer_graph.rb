# frozen_string_literal: true

# Persistent snapshot of the Framework Explorer's view model. One row per
# framework; its `graph_blob` is a Marshal-serialized
# {Frameworks::ExplorerGraph::Framework} value tree.
#
# Written by {Frameworks::ExplorerGraph.store} inside the same DB transaction
# as every framework event (see {Frameworks::Repository#with_framework}).
# Read by {Frameworks::ExplorerGraph.load}.
#
# `format_version` is bumped whenever the serialized graph shape changes;
# stale rows are treated as missing so the controller falls back to a lazy
# {Frameworks::ExplorerGraph.rebuild} from the aggregate.
#
class FrameworkExplorerGraph < ApplicationRecord
  self.table_name = "framework_explorer_graphs"
  self.primary_key = "framework_id"

  validates :graph_blob, presence: true
  validates :format_version, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
end
