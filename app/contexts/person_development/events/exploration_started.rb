# frozen_string_literal: true

# Event emitted when a person, their reporting manager or a rating delegate
# declares an exploration: the intent to look seriously at another role or
# level (ADR-22, "declared exploration").
#
# An intent fact, not a rating scope — ratings stay facts about cells and the
# lens reads them. Needs a framework assignment but no open cycle: declaring
# writes no rating, so the open-cycle rule for ratings (D7) doesn't apply.
# One exploration per target role is open at a time.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :exploration_id caller-minted UUID v7 — the read
#     model's primary key
#   @option data [String] :target_role_id the role being explored
#   @option data [String] :target_level_id the level of that role
#   @option data [Integer] :target_level_ordinal that level's ordinal, so
#     readers can name "PM3" without a framework lookup
#   @option data [String, nil] :started_by_id UUID of the Person who declared it
#   @option data [String, nil] :note optional note from the declarer
#
class PersonDevelopment::Events::ExplorationStarted < RubyEventStore::Event
end
