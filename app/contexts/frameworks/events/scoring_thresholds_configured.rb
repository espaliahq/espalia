# frozen_string_literal: true

# Event emitted when scoring thresholds are configured on a framework.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [BigDecimal, nil] :mastery_threshold ratio above baseline
#     required to be considered "mastering" the current level (e.g. 1.15)
#   @option data [BigDecimal, nil] :promotion_score_threshold ratio of
#     next-level baseline required for promotion readiness (e.g. 0.90)
#
class Frameworks::Events::ScoringThresholdsConfigured < RubyEventStore::Event
end
