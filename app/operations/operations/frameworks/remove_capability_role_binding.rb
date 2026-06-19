# frozen_string_literal: true

# Removes a capability-role binding — un-scopes a capability from a role.
#
# Shape-changing — it alters which roles the capability applies to, so it
# auto-opens a draft (see Frameworks::Aggregate#remove_capability_role_binding)
# and is deferred from the published read model until publish. Recoverable
# before publish (re-add the binding).
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#remove_binding?).
class Operations::Frameworks::RemoveCapabilityRoleBinding < Operations::Base
  description "Remove a capability-role binding, un-scoping the capability from that role (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :binding_id,   String, required: true

  def policy_check
    authorize framework, :remove_binding?
  end

  # @return [Hash] { framework_id:, binding_id:, capability_id:, role_id:, removed: }
  def perform
    Frameworks::CommandHandler.new.remove_capability_role_binding(
      framework.framework_id, binding.binding_id
    )

    {
      framework_id: framework.framework_id,
      binding_id: binding.binding_id,
      capability_id: binding.capability_id,
      role_id: binding.role_id,
      removed: true
    }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Resolve from the explorer graph (incl. bindings created in the current
  # draft), which also scopes the lookup to the authorized framework.
  def binding
    @binding ||= explorer_graph.capability_categories
      .flat_map(&:capabilities)
      .flat_map(&:bindings)
      .find { |b| b.binding_id == params[:binding_id] } ||
      raise(ActiveRecord::RecordNotFound, "binding #{params[:binding_id]} not found in this framework")
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
