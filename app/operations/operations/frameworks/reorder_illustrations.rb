# frozen_string_literal: true

# Reorders the illustrations for one expectation × role. Takes the COMPLETE
# ordered list of illustration ids — a single atomic event
# (RoleIllustrationReordered), one feed entry, and an MCP tool an agent can
# drive without N swap calls. Display-order only, so it is shape-preserving:
# applies live, no draft.
#
# The web's ↑/↓ chevrons post a neighbour-relative move; the controller
# translates that into the full list before dispatching here, so web and MCP
# share this one implementation (the house rule).
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#reorder_illustrations?).
class Operations::Frameworks::ReorderIllustrations < Operations::Base
  description "Reorder the illustrations for one expectation and role (owner/editor/lead only). " \
              "Pass the complete list of illustration ids in the desired display order."
  category :write
  approval :mcp_client

  parameter :framework_id,   String, required: true
  parameter :expectation_id, String, required: true
  parameter :role_id,        String, required: true
  parameter :new_ordering,   Array,  required: true,
                             schema: { type: "array", items: { type: "string" },
                                       description: "Every illustration id for this expectation × role, in the desired order" }

  def policy_check
    authorize framework, :reorder_illustrations?
  end

  # @return [Hash] { framework_id:, expectation_id:, role_id:, new_ordering: }
  def perform
    ensure_permutation!

    Frameworks::CommandHandler.new.reorder_role_illustrations(
      framework.framework_id, params[:expectation_id], params[:role_id], new_ordering
    )

    {
      framework_id: framework.framework_id,
      expectation_id: params[:expectation_id],
      role_id: params[:role_id],
      new_ordering: new_ordering
    }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def new_ordering
    @new_ordering ||= params[:new_ordering].map(&:to_s)
  end

  # The ordering must be exactly a permutation of the illustrations that exist
  # for this expectation × role — a foreign / missing / duplicated id is a
  # client mistake (→ -32602 for MCP), never an internal error. This also
  # blocks renumbering illustrations that belong to another expectation via a
  # smuggled id (the projection updates rows by illustration_id alone).
  # Scoped to THIS framework via role → role_family (mcp-server.md Lesson 5).
  def ensure_permutation!
    current_ids = FrameworkState::RoleIllustration
      .joins(role: :role_family)
      .where(framework_role_families: { framework_id: framework.framework_id })
      .where(expectation_id: params[:expectation_id], role_id: params[:role_id])
      .pluck(:illustration_id)

    if current_ids.empty?
      raise Operations::Base::ParameterError,
            "no illustrations found for expectation #{params[:expectation_id]} and role #{params[:role_id]}"
    end
    return if new_ordering.sort == current_ids.sort

    raise Operations::Base::ParameterError,
          "new_ordering must be a permutation of the #{current_ids.size} illustration id(s) " \
          "for this expectation and role"
  end
end
