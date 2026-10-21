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
  # @param imported [Boolean] the item came in through the feedback exchange
  #   ({ExternalReference#imported?}), so its system is a peer even when it
  #   shares a link target's slug
  # @return [String] the origin key reports group by; nil, blank and link
  #   targets are GrowthOS
  def self.key_for(system, imported: false)
    key = system.to_s.strip.downcase.tr("-", "_")
    return NATIVE if key.empty?
    return key if imported

    ExternalReference::LINK_SYSTEMS.include?(key) ? NATIVE : key
  end

  # @param key [String, nil] an origin key, or a raw system slug
  # @param imported [Boolean] see {.key_for}
  # @return [String] a display name, falling back to the titleised slug
  def self.label(key, imported: false)
    peer_label(key_for(key, imported: imported))
  end

  # The display name for an origin key (from {.key_for}, or a report's
  # `by_origin`) or for an imported item's peer slug. Unlike {.label} it reads
  # the slug as given, so a peer is never mistaken for a link target.
  #
  # @param slug [String] an origin key or a peer's `external_reference.system`
  # @return [String]
  def self.peer_label(slug)
    key = slug.to_s.strip.downcase.tr("-", "_")
    LABELS.fetch(key) { key.tr("_", " ").titleize }
  end
end
