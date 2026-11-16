# frozen_string_literal: true

# The tenant's pricing inputs as they stood when the plan was archived, so
# its figures hold still until it is restored. Recorded with each
# {PlanArchived}; a {PlanRestored} sets it aside, and the next archive
# records a fresh copy.
#
# The copy is tenant configuration, sealed under the plan's key so deleting
# the plan erases it. It names nobody: who last edited a row is left out, and
# nothing derived from a person's actual pay is in it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [Shreddable::Value] :inputs as {TeamPlanning::PricingInputs.capture} gives them
#
class TeamPlanning::Events::PlanPricesFrozen < RubyEventStore::Event
  extend Shreddable

  shreddable :inputs, by: :plan
end
