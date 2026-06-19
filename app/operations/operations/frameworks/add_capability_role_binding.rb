# frozen_string_literal: true

# Binds an existing capability to a role — the way to re-scope a capability to
# additional roles after it was created (the add-capability modal only sets the
# *initial* bindings). A capability bound to no role is hidden from the
# role-filtered matrix, so adding a binding makes it visible to that role.
#
# Shape-changing — adding a binding alters which roles the capability applies to,
# so it auto-opens a draft (see Frameworks::Aggregate#create_capability_role_binding)
# and is deferred from the published read model until publish.
#
# Optional scoring levers (default to the framework/category-governed behaviour):
#   weight                — relative contribution weight (default 1.0)
#   individual_tolerance  — nil = category-governed, 0 = mandatory, N = capped
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#add_binding?).
class Operations::Frameworks::AddCapabilityRoleBinding < Operations::Base
  description "Bind a capability to a role, optionally with a weight / individual tolerance (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id,         String,  required: true
  parameter :capability_id,        String,  required: true
  parameter :role_id,              String,  required: true
  parameter :weight,               Numeric
  parameter :individual_tolerance, Numeric

  def policy_check
    authorize framework, :add_binding?
  end

  # @return [Hash] { framework_id:, binding_id:, capability_id:, role_id:, weight:, individual_tolerance: }
  def perform
    validate_levers!
    ensure_role!
    ensure_not_already_bound!

    binding_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.create_capability_role_binding(
      framework.framework_id, binding_id, capability.capability_id, params[:role_id],
      weight: params[:weight] || 1.0, individual_tolerance: params[:individual_tolerance]
    )

    {
      framework_id: framework.framework_id,
      binding_id: binding_id,
      capability_id: capability.capability_id,
      role_id: params[:role_id],
      weight: params[:weight] || 1.0,
      individual_tolerance: params[:individual_tolerance]
    }
  end

  private

  def validate_levers!
    if params[:weight] && params[:weight] <= 0
      raise Operations::Base::ParameterError, "weight must be greater than 0"
    end
    if params[:individual_tolerance] && params[:individual_tolerance].negative?
      raise Operations::Base::ParameterError, "individual_tolerance must be 0 or greater"
    end
  end

  # Roles are not draft-editable today, so the published read model is
  # authoritative. Scope the lookup to this framework's role families.
  def ensure_role!
    family_ids = FrameworkState::RoleFamily.where(framework_id: framework.framework_id).pluck(:role_family_id)
    return if FrameworkState::Role.exists?(role_family_id: family_ids, role_id: params[:role_id])

    raise Operations::Base::ParameterError, "unknown role #{params[:role_id]} for this framework"
  end

  # The read model enforces a unique (capability, role) binding; pre-empt that
  # with a clean error. Checks the graph so a binding created earlier in the
  # current draft (deferred from the read model) is still caught.
  def ensure_not_already_bound!
    return unless capability.bindings.any? { |b| b.role_id == params[:role_id] }

    raise Operations::Base::ParameterError,
          "capability #{capability.capability_id} is already bound to role #{params[:role_id]}"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Resolve from the explorer graph (incl. draft-added capabilities), which also
  # scopes the lookup to the authorized framework.
  def capability
    @capability ||= explorer_graph.capability_categories.flat_map(&:capabilities)
      .find { |c| c.capability_id == params[:capability_id] } ||
      raise(ActiveRecord::RecordNotFound, "capability #{params[:capability_id]} not found in this framework")
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
