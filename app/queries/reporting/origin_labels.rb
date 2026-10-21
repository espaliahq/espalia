# frozen_string_literal: true

# Display names for where a piece of feedback was given, read from
# `external_reference.system`. Feedback is foreign only when it came from
# another feedback system; a nil system, or one of the plain link targets in
# `ExternalReference::LINK_SYSTEMS` (a GitHub PR, a Slack message, a Notion
# doc someone pointed at), was given in GrowthOS. Shared by the cycle report,
# the feedback export and anything else that shows origin.
module Reporting::OriginLabels
  NATIVE = "growthos"

  LABELS = {
    NATIVE => "GrowthOS",
    "chip" => "Chip"
  }.freeze

  # @param system [String, nil] `external_reference.system`
  # @return [String] the origin key reports group by; nil, blank and link
  #   targets are GrowthOS
  def self.key_for(system)
    key = system.to_s.strip.downcase.tr("-", "_")
    return NATIVE if key.empty? || ExternalReference::LINK_SYSTEMS.include?(key)

    key
  end

  # @param key [String, nil] an origin key, or a raw system slug
  # @return [String] a display name, falling back to the titleised slug
  def self.label(key)
    key = key_for(key)
    LABELS.fetch(key) { key.tr("_-", "  ").titleize }
  end
end
