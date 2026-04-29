# frozen_string_literal: true

# Event emitted when seed_ratings_from_prior_cycle skips a capability
# during cycle enrolment because that capability's stable_id is no
# longer present in the new cycle's framework version.
#
# Audit-only — there is no projection writing a read model row, and
# no UI surface today. The event records the skip on the
# person-development stream so the migration UI (when it ships) can
# replay these and offer "use this rating" against the migrated
# equivalent capability.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id stable UUID of the prior capability
#   @option data [Integer] :level_ordinal level the prior aligned value sat at
#   @option data [String] :prior_aligned_frequency frequency that would have been seeded
#   @option data [String] :current_cycle_id UUID of the cycle being seeded into
#   @option data [String] :prior_cycle_id UUID of the cycle the value came from
#   @option data [String] :reason machine-friendly reason — e.g.
#     "capability_not_in_current_framework"
#
class PersonDevelopment::Events::RatingSeedSkipped < RubyEventStore::Event
end
