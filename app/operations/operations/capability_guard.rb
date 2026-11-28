# frozen_string_literal: true

# Refuses a write on a capability that isn't active in the published
# framework: a retired one, a draft-only one, one from another framework or
# a made-up id all get the same answer (#615).
#
# It reads the published framework even for a person a publish skipped
# because their alignment was complete (ADR-17): every screen renders them
# against the published grid too, and nothing new may land on a capability
# that grid no longer shows.
module Operations::CapabilityGuard
  private

  # @param framework_id [String]
  # @param stable_id [String]
  # @raise [Operations::Base::ParameterError]
  def ensure_active_capability!(framework_id, stable_id)
    uuid = stable_id.is_a?(String) && stable_id.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    return if uuid && FrameworkState::Capability.active_in_framework(framework_id).exists?(stable_id: stable_id)

    raise Operations::Base::ParameterError,
      "capability_stable_id #{stable_id} is not an active capability in the published framework"
  end
end
