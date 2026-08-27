# frozen_string_literal: true

# Updates an existing capability-role binding's scoring levers — its `weight`
# and/or `individual_tolerance`. This is the only way to re-tune how a
# capability contributes to a role's score after the binding has been created.
#
# Shape-preserving: it does NOT alter the (capability_stable_id, level_ordinal)
# rating grid, so it applies live (no draft required) — see ADR-16 and
# Frameworks::Aggregate#update_capability_role_binding.
#
# `individual_tolerance` semantics (maps to the read model's deficit_threshold):
#   nil — governed by category / framework default
#   0   — no deficit allowed (mandatory)
#   N   — contribution deficit up to N tolerated before blocking verdicts
# Clearing a set tolerance back to nil is not supported here — the command
# handler `.compact`s nil values, so a nil argument means "leave unchanged".
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#update_binding?).
class Operations::Frameworks::UpdateCapabilityRoleBinding < Operations::Base
  description "Update a capability-role binding's weight and/or individual tolerance (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id,         String,  required: true
  parameter :binding_id,           String,  required: true
  parameter :weight,               Numeric
  parameter :individual_tolerance, Numeric
  requires_any_of :weight, :individual_tolerance

  def policy_check
    authorize framework, :update_binding?
  end

  # @return [Hash] { framework_id:, binding_id:, capability_id:, role_id:, weight:, individual_tolerance: }
  def perform
    validate_changes!

    Frameworks::CommandHandler.new.update_capability_role_binding(
      framework.framework_id, binding.binding_id,
      weight: params[:weight], individual_tolerance: params[:individual_tolerance]
    )

    {
      framework_id: framework.framework_id,
      binding_id: binding.binding_id,
      capability_id: binding.capability_id,
      role_id: binding.role_id,
      weight: params[:weight] || binding.weight,
      individual_tolerance: params[:individual_tolerance] || binding.individual_tolerance
    }
  end

  private

  # Values must be in range, so the caller gets a clean ParameterError rather
  # than a downstream validation failure from the read model. ("At least one
  # lever supplied" is declared as `requires_any_of` above — a range is not
  # something JSON Schema `required` can carry, so it stays here.)
  def validate_changes!
    if params[:weight] && params[:weight] <= 0
      raise Operations::Base::ParameterError, "weight must be greater than 0"
    end
    if params[:individual_tolerance] && params[:individual_tolerance].negative?
      raise Operations::Base::ParameterError, "individual_tolerance must be 0 or greater"
    end
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Resolve from the explorer graph (NOT the read model) so a binding created
  # in the current draft — deferred from FrameworkState::CapabilityRoleBinding
  # but present in the graph — can still be tuned. The graph is per-framework,
  # so finding the id in it scopes the lookup to the authorized framework
  # (guards against tuning a binding belonging to another framework).
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
