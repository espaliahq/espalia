# frozen_string_literal: true

# The plan reads reused inside {TeamPlanning::Resolution.reusing}. A
# CurrentAttributes, so Rails resets it after every request and job even if
# the block's own cleanup never runs.
class CurrentPlanReads < ActiveSupport::CurrentAttributes
  # @return [Hash{Array => TeamPlanning::Baseline::Map}, nil] nil outside a reusing block
  attribute :memo

  # The controller builds a context per call, so reads key on who it names.
  #
  # @param context [AuthorizationContext]
  # @return [Array(String, String, String)]
  def self.viewer(context) = [ context.user&.id, context.tenant_user&.id, context.person&.id ]

  # @param key [Array] what the read depends on, the viewer among it
  # @yield the read, run only on a miss
  # @return [Object] the read's result
  def self.fetch(key)
    return yield unless memo

    memo.fetch(key) { memo[key] = yield }
  end
end
