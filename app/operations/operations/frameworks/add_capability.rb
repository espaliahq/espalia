# frozen_string_literal: true

# Adds a capability to a category and binds it to one or more roles in the same
# action so it is immediately visible in the role-filtered matrix. At least one
# role is required — a capability bound to no role is hidden, so an unbound one
# is never what the caller wants. Shape-changing — adding a capability auto-opens
# a draft (see Frameworks::Aggregate#ensure_draft_in_progress!).
#
# Write — :mcp_client. It stages a structural change into the open draft;
# the live impact happens at publish (:in_app). Restricted to edit-rights
# holders (FrameworkPolicy#add_capability?).
class Operations::Frameworks::AddCapability < Operations::Base
  description "Add a capability to a category, binding it to one or more roles (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :category_id,  String, required: true
  parameter :name,         String, required: true
  parameter :description,  String
  parameter :role_ids,     Array, required: true,
                           schema: { type: "array", items: { type: "string", minLength: 1 }, minItems: 1,
                                     description: "At least one role id to bind the capability to — " \
                                                  "a capability bound to no role is hidden from the role-filtered matrix" }

  def policy_check
    authorize framework, :add_capability?
  end

  # @return [Hash] { framework_id:, capability_id:, stable_id:, bound_role_ids: }
  def perform
    # Validate parent + bindings BEFORE adding the capability so we never
    # persist a half-built capability (added, then a bad binding fails).
    ensure_category!
    role_ids = validated_role_ids

    capability_id = SecureRandom.uuid_v7
    stable_id = SecureRandom.uuid_v7
    handler = Frameworks::CommandHandler.new
    handler.add_capability(
      framework.framework_id, capability_id, stable_id, params[:category_id], params[:name],
      description: params[:description].presence
    )
    role_ids.each do |role_id|
      handler.create_capability_role_binding(
        framework.framework_id, SecureRandom.uuid_v7, capability_id, role_id
      )
    end

    {
      framework_id: framework.framework_id,
      capability_id: capability_id,
      stable_id: stable_id,
      bound_role_ids: role_ids
    }
  end

  private

  def ensure_category!
    return if FrameworkState::CapabilityCategory
              .exists?(framework_id: framework.framework_id, category_id: params[:category_id])

    raise Operations::Base::ParameterError, "category #{params[:category_id]} not found in this framework"
  end

  # Role ids that exist in this framework. Requires at least one — a capability
  # bound to no role is hidden from the role-filtered matrix, so an unbound
  # capability is never what the caller wants. Raises on any unknown id so we
  # never add the capability and then fail (or silently skip) a binding.
  def validated_role_ids
    requested = Array(params[:role_ids]).compact_blank
    if requested.empty?
      raise Operations::Base::ParameterError, "select at least one role to bind the capability to"
    end

    family_ids = FrameworkState::RoleFamily.where(framework_id: framework.framework_id).pluck(:role_family_id)
    valid = FrameworkState::Role.where(role_family_id: family_ids, role_id: requested).pluck(:role_id)
    missing = requested - valid
    raise Operations::Base::ParameterError, "unknown role(s) for this framework: #{missing.join(', ')}" if missing.any?

    valid
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
