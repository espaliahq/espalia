# frozen_string_literal: true

# Reorders a category's capabilities. Takes the COMPLETE ordered list of the
# category's active capability ids — one atomic event (CapabilityReordered),
# one feed entry, and an MCP tool an agent can drive without N swap calls.
# Display-order only, so it is shape-preserving: applies live, no draft.
#
# Validates against the ExplorerGraph, not the read model: a draft-added
# capability is reorderable in the edit matrix but absent from the read model
# until publish (framework-explorer.md Lesson 17). The reorderable set is the
# graph's active, not-pending-archive capabilities — exactly what the edit
# matrix renders un-struck — matching the aggregate's own invariant.
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#reorder_capabilities?).
class Operations::Frameworks::ReorderCapabilities < Operations::Base
  description "Reorder the capabilities within one category (owner/editor/lead only). " \
              "Pass the complete list of the category's active capability ids in the desired display order."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :category_id,  String, required: true
  parameter :new_ordering, Array,  required: true,
                           schema: { type: "array", items: { type: "string" },
                                     description: "Every active capability id in this category, in the desired display order" }

  def policy_check
    authorize framework, :reorder_capabilities?
  end

  # @return [Hash] { framework_id:, category_id:, new_ordering: }
  def perform
    ensure_permutation!

    Frameworks::CommandHandler.new.reorder_capabilities(
      framework.framework_id, category.category_id, new_ordering
    )

    { framework_id: framework.framework_id, category_id: category.category_id, new_ordering: new_ordering }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def graph
    @graph ||= Frameworks::ExplorerGraph.load(framework.framework_id)
  end

  # Graph resolution scopes the category to the authorized framework (the
  # graph is per-framework) and covers draft-added categories for free.
  def category
    @category ||= graph.capability_categories.find { |c| c.category_id == params[:category_id] } ||
                  raise(ActiveRecord::RecordNotFound, "category #{params[:category_id]} not found")
  end

  def new_ordering
    @new_ordering ||= params[:new_ordering].map(&:to_s)
  end

  # Must be exactly a permutation of the category's reorderable capabilities
  # (active + not staged for archive) — a foreign / missing / duplicated id is
  # a client mistake (→ -32602 for MCP). The aggregate re-validates as the
  # backstop.
  def ensure_permutation!
    current_ids = category.capabilities
      .reject { |c| c.status != "active" || (c.respond_to?(:pending_archive) && c.pending_archive) }
      .map(&:capability_id)

    return if new_ordering.sort == current_ids.sort

    raise Operations::Base::ParameterError,
          "new_ordering must be a permutation of the #{current_ids.size} active capability id(s) " \
          "in this category (capabilities staged for archive are not reorderable)"
  end
end
