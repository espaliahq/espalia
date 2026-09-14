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
  # 2: pending_archive derives from the draft's own archives, not from every
  #    archived capability (stored snapshots re-derive it on next load).
  FORMAT_VERSION = 2

  module_function

  # Serializes the graph as a plain hash tree (jsonb on the Postgres side)
  # and upserts its row. Intended to be called inside the same DB
  # transaction as the event write that produced it.
  #
  # @param framework_id [String]
  # @param graph [Frameworks::ExplorerGraph::Framework]
  # @return [FrameworkExplorerGraph]
  def store(framework_id, graph)
    row = FrameworkExplorerGraph.find_or_initialize_by(framework_id: framework_id)
    row.graph_data = graph.to_hash_tree
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

    Frameworks::ExplorerGraph::Framework.from_hash_tree(row.graph_data)
  end

  # Loads the aggregate, builds a fresh graph, stores it. Used as a lazy
  # fallback when `load` returns nil, and by {rebuild_all!} after a
  # FORMAT_VERSION bump.
  #
  # Falls back to the AR-based builder when the event stream is empty (test
  # factories that create `FrameworkState::Framework` rows directly bypass
  # the command path and therefore have no events). Snapshots are not
  # persisted in that case — there's no authoritative aggregate to keep
  # them in sync with.
  #
  # @param framework_id [String]
  # @return [Frameworks::ExplorerGraph::Framework]
  def rebuild(framework_id)
    graph = nil
    Frameworks::Repository.new.with_framework(framework_id) do |agg|
      graph = Frameworks::ExplorerGraphBuilder.new(agg).build if agg.framework_id
    end

    if graph
      store(framework_id, graph)
      return graph
    end

    ar_framework = FrameworkState::Framework.find_by(framework_id: framework_id)
    raise "No framework #{framework_id} in event stream or AR read model" unless ar_framework

    Frameworks::ExplorerGraph::ArBuilder.new(ar_framework).build
  end

  # Rebuilds every framework's graph across every tenant. Run after a
  # FORMAT_VERSION bump.
  #
  # The initial enumeration uses `ActsAsTenant.without_tenant` so a caller
  # holding an ambient tenant context (mid-request, or a seed/rake step
  # that ran `with_tenant` earlier) still sees every framework. The
  # per-framework rebuild then re-enters the correct tenant for its events.
  #
  # @yield [framework_id, index, total]
  def rebuild_all!
    ids = ActsAsTenant.without_tenant do
      FrameworkState::Framework.pluck(:framework_id, :tenant_id)
    end
    ids.each_with_index do |(fid, tenant_id), i|
      ActsAsTenant.with_tenant(Tenant.find(tenant_id)) do
        rebuild(fid)
      end
      yield(fid, i + 1, ids.size) if block_given?
    end
  end
end
