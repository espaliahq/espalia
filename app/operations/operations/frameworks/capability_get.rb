# frozen_string_literal: true

# Drill-in for a single capability within a framework: description,
# status, bindings (which roles have it + weight), and the expectations
# per level with their illustrations grouped by role. This is the
# detail layer that frameworks_get hides — bounded payload per
# capability so the LLM can fetch only what it needs.
#
# Read-only; scoped by acts_as_tenant and FrameworkPolicy#show?.
class Operations::Frameworks::CapabilityGet < Operations::Base
  description "Fetch one capability's full detail: bindings, expectations per level, illustrations."
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

  def capability
    @capability ||= FrameworkState::Capability
      .includes(:category)
      .find_by!(capability_id: params[:capability_id])
  end
end
