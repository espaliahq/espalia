# frozen_string_literal: true

# Reorders the framework's capability categories. Takes the COMPLETE ordered
# list of active category ids — one atomic event
# (CapabilityCategoryReordered), one feed entry, and an MCP tool an agent can
# drive without N swap calls. Display-order only, so it is shape-preserving:
# applies live, no draft.
#
# The web's ↑/↓ chevrons on the category header post a neighbour-relative
# move; the controller translates it into the full list before dispatching
# here, so web and MCP share one implementation (the house rule).
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#reorder_categories?).
class Operations::Frameworks::ReorderCategories < Operations::Base
  description "Reorder the framework's capability categories (owner/editor/lead only). " \
              "Pass the complete list of active category ids in the desired display order."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :new_ordering, Array,  required: true,
                           schema: { type: "array", items: { type: "string" },
                                     description: "Every active category id, in the desired display order" }

  def policy_check
    authorize framework, :reorder_categories?
  end

  # @return [Hash] { framework_id:, new_ordering: }
  def perform
    ensure_permutation!

    Frameworks::CommandHandler.new.reorder_capability_categories(
      framework.framework_id, new_ordering
    )

    { framework_id: framework.framework_id, new_ordering: new_ordering }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def new_ordering
    @new_ordering ||= params[:new_ordering].map(&:to_s)
  end

  # Must be exactly a permutation of the framework's ACTIVE categories — a
  # foreign / missing / duplicated id is a client mistake (→ -32602 for MCP).
  # The aggregate re-validates against its own state as the backstop.
  def ensure_permutation!
    current_ids = FrameworkState::CapabilityCategory
      .where(framework_id: framework.framework_id, status: "active")
      .pluck(:category_id)

    return if new_ordering.sort == current_ids.sort

    raise Operations::Base::ParameterError,
          "new_ordering must be a permutation of the #{current_ids.size} active category id(s) " \
          "for this framework"
  end
end
