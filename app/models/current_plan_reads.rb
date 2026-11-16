# frozen_string_literal: true

# The plan reads reused inside {TeamPlanning::Resolution.reusing}. A
# CurrentAttributes, so Rails resets it after every request and job even if
# the block's own cleanup never runs.
class CurrentPlanReads < ActiveSupport::CurrentAttributes
  # @return [Hash{Array => TeamPlanning::Baseline::Map}, nil] nil outside a reusing block
  attribute :memo

  # @return [Hash{String => Hash, nil}] each sealed price copy revealed, by its event's id
  attribute :copies

  # @return [Hash{Hash => TeamPlanning::PricingInputs}] each revealed copy's inputs, by the copy itself
  attribute :frozen_inputs

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

  # A stored event never changes, so its copy is revealed once per request
  # or job, inside a reusing block or not.
  #
  # @param event_id [String]
  # @yield the reveal, run only on a miss
  # @return [Hash, nil]
  def self.copy(event_id)
    self.copies ||= {}
    copies.fetch(event_id) { copies[event_id] = yield }
  end

  # @param copy [Hash] as {.copy} revealed it
  # @yield builds the inputs, run only on a miss
  # @return [TeamPlanning::PricingInputs]
  def self.frozen_inputs_for(copy)
    self.frozen_inputs ||= {}.compare_by_identity
    frozen_inputs.fetch(copy) { frozen_inputs[copy] = yield }
  end

  # Called wherever a plan key is destroyed, so nothing a copy revealed
  # outlives the key it was sealed under.
  def self.forget_copies
    copies&.clear
    frozen_inputs&.clear
  end
end
