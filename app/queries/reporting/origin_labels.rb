# frozen_string_literal: true

# Display names for where a piece of feedback was given, read from
# `external_reference.system`. A nil system means GrowthOS itself. Shared by
# the cycle report, the feedback export and anything else that shows origin.
module Reporting::OriginLabels
  NATIVE = "growthos"

  LABELS = {
    NATIVE => "GrowthOS",
    "slack" => "Slack",
    "chip" => "Chip",
    "github" => "GitHub",
    "gitlab" => "GitLab",
    "linear" => "Linear",
    "jira" => "Jira",
    "notion" => "Notion",
    "google_doc" => "Google Docs",
    "figma" => "Figma"
  }.freeze

  # @param system [String, nil] `external_reference.system`
  # @return [String] the origin key reports group by; nil and blank are GrowthOS
  def self.key_for(system)
    system.to_s.strip.downcase.tr("-", "_").presence || NATIVE
  end

  # @param key [String, nil] an origin key, or a raw system slug
  # @return [String] a display name, falling back to the titleised slug
  def self.label(key)
    key = key_for(key)
    LABELS.fetch(key) { key.tr("_-", "  ").titleize }
  end
end
