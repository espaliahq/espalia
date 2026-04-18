# frozen_string_literal: true

# Dedicated view model for the Framework Explorer.
#
# Provides `store` / `load` / `rebuild` against the `framework_explorer_graphs`
# table, which holds one Marshal-serialized
# {Frameworks::ExplorerGraph::Framework} per framework. Written atomically
# with each framework event (see {Frameworks::Repository#with_framework});
# read by `FrameworksController` for both view and edit modes.
#
# The serialized payload's shape is tagged with {FORMAT_VERSION}; rows
# carrying an older format are treated as missing on read, causing the
# controller to lazily rebuild from the aggregate.
#
module Frameworks::ExplorerGraph
  # Bump whenever the serialized graph shape changes in a
  # backwards-incompatible way. Lazy rebuild on mismatch makes the bump a
  # zero-downtime operation; running `rebuild_all!` as a deploy step
  # refreshes all rows.
  FORMAT_VERSION = 1

  module_function

  # Serializes the graph and upserts its row. Intended to be called inside
  # the same DB transaction as the event write that produced it.
  #
  # @param framework_id [String]
  # @param graph [Frameworks::ExplorerGraph::Framework]
  # @return [FrameworkExplorerGraph]
  def store(framework_id, graph)
    blob = Marshal.dump(graph)
    row = FrameworkExplorerGraph.find_or_initialize_by(framework_id: framework_id)
    row.graph_blob = blob
    row.format_version = FORMAT_VERSION
    row.save!
    row
  end

  # @param framework_id [String]
  # @return [Frameworks::ExplorerGraph::Framework, nil] nil if missing or
  #   stored under an older format version
  def load(framework_id)
    row = FrameworkExplorerGraph.find_by(framework_id: framework_id)
    return nil if row.nil?
    return nil if row.format_version != FORMAT_VERSION

    Marshal.load(row.graph_blob) # rubocop:disable Security/MarshalLoad
  end

  # Loads the aggregate, builds a fresh graph, stores it. Used as a lazy
  # fallback when `load` returns nil, and by {rebuild_all!} after a
  # FORMAT_VERSION bump.
  #
  # @param framework_id [String]
  # @return [Frameworks::ExplorerGraph::Framework]
  def rebuild(framework_id)
    graph = nil
    Frameworks::Repository.new.with_framework(framework_id) do |agg|
      graph = Frameworks::ExplorerGraphBuilder.new(agg).build
    end
    store(framework_id, graph)
    graph
  end

  # Rebuilds every framework's graph. Run after a FORMAT_VERSION bump.
  # Yields progress for callers that want to log it.
  #
  # @yield [framework_id, index, total]
  def rebuild_all!
    ids = FrameworkState::Framework.pluck(:framework_id, :tenant_id)
    ids.each_with_index do |(fid, tenant_id), i|
      ActsAsTenant.with_tenant(Tenant.find(tenant_id)) do
        rebuild(fid)
      end
      yield(fid, i + 1, ids.size) if block_given?
    end
  end
end
