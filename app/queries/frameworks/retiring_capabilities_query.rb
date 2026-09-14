# frozen_string_literal: true

# The capabilities a framework's open draft retires, paired with the
# migration mapping recorded for each — the publish gate ADR-17 enforces,
# read from the edit-mode graph so the review page and the publish request
# see one answer.
#
# Only capabilities that existed before the draft count: a capability added
# and archived within the same draft has nothing to migrate.
class Frameworks::RetiringCapabilitiesQuery
  # @param framework [FrameworkState::Framework]
  def initialize(framework)
    @framework = framework
  end

  # @return [Array<Hash>] `{ capability:, mapping: }` per retiring capability;
  #   `mapping` is nil when none has been recorded yet
  def call
    mappings = FrameworkState::MigrationMapping.for_draft(@framework).index_by(&:from_stable_id)

    graph_capabilities
      .select { |c| c.pending_archive && !c.added_in_draft }
      .map { |c| { capability: c, mapping: mappings[c.stable_id] } }
  end

  # @return [Array<String>] names of retiring capabilities still without a mapping
  def unmapped_names
    call.filter_map { |entry| entry[:capability].name if entry[:mapping].nil? }
  end

  # Capabilities that will exist post-publish — survivor candidates for
  # evolved/split mappings. Neither the retiring ones nor those archived in
  # an earlier version (still in the graph, but gone from the published view).
  #
  # @return [Array<Hash>] `{ name:, stable_id: }`, sorted by name
  def survivors
    graph_capabilities
      .reject { |c| c.pending_archive || c.status == "archived" }
      .map { |c| { name: c.name, stable_id: c.stable_id } }
      .sort_by { |c| c[:name] }
  end

  private

  # All capability nodes from the edit-mode graph, loaded once. The archive
  # is deferred from the published read model during a draft, so the graph
  # is the only place the pending state lives.
  def graph_capabilities
    @graph_capabilities ||= begin
      graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
              Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
      graph.capability_categories.flat_map(&:capabilities)
    end
  end
end
