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
#   @option data [BigDecimal, nil] :underperforming_threshold ratio below
#     which the person is classified as underperforming rather than
#     progressing toward the current level (e.g. 0.80)
#   @option data [Integer, nil] :overperformance_cap levels above assigned
#     level that contribute to score (e.g. 1)
#   @option data [BigDecimal, nil] :deficit_threshold weighted deficit above
#     which a capability is flagged as blocked (e.g. 1.0)
#
class Frameworks::Events::ScoringThresholdsConfigured < RubyEventStore::Event
end
