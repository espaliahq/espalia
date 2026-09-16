# frozen_string_literal: true

# Drill-in for a single capability within a framework: description,
# status, bindings (which roles have it + weight), and the expectations
# per level with their illustrations grouped by role. This is the
# detail layer that frameworks_get hides — bounded payload per
# capability so the LLM can fetch only what it needs.
#
# Read-only; scoped by acts_as_tenant and FrameworkPolicy#show?.
class Operations::Frameworks::CapabilityGet < Operations::Base
  description "Fetch one capability's full detail: bindings, expectations per level, examples (the illustrations key). " \
              "Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument."
  category :read
  approval :none

  parameter :framework_id,  String, required: true
  parameter :capability_id, String, required: true

  def policy_check
    authorize framework, :show?
  end

  # @return [Hash] as defined by {Mcp::FrameworkSerializer.capability}.
  def perform
    Mcp::FrameworkSerializer.capability(framework, capability)
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Scope the lookup through the framework's categories so a
  # capability_id belonging to a different framework in the same tenant
  # can't be requested under this framework's authorization. Without
  # this join, only the tenant boundary protects against cross-framework
  # ID confusion — which is too weak when a tenant has multiple
  # frameworks.
  #
  # Accepts the value as either a capability_id (per-version) or a
  # stable_id (cross-version). LLM clients regularly pass stable_id —
  # the cross-version handle also returned by parent calls like
  # frameworks_get — into the capability_id argument. Look up by either.
  def capability
    @capability ||= begin
      scope = FrameworkState::Capability
        .joins(:category)
        .where(framework_capability_categories: { framework_id: framework.framework_id })
        .includes(:category)
      identifier = params[:capability_id]
      scope.find_by(capability_id: identifier) || scope.find_by!(stable_id: identifier)
    end
  end
end
