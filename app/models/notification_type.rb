# frozen_string_literal: true

# Registry of every notification type the platform can emit, with the
# channels it supports and the per-channel default delivery preference.
#
# This is the single source of truth for:
#   - which notification types exist (drives the settings UI),
#   - which channels are available, and
#   - the default on/off state of each channel per type.
#
# Users store only *overrides* in `User#notification_preferences`; effective
# state is resolved here (override if present, else the registry default), so
# introducing a new type never requires a data backfill.
#
# Channels:
#   :in_app — always-immediate in-product notification (Noticed database + cable)
#   :slack  — per-tenant Slack DM (resolved at dispatch time; see Slack delivery)
#   :email  — transactional email (delivery wired in a later phase)
class NotificationType
  # All channels a notification can be delivered over, in display order.
  CHANNELS = %i[in_app slack email].freeze

  # A single notification type definition.
  #
  # @!attribute [r] key [Symbol] stable identifier (also the prefs hash key)
  # @!attribute [r] label [String] human label for the settings UI
  # @!attribute [r] description [String] one-line explanation for the settings UI
  # @!attribute [r] defaults [Hash{Symbol=>Boolean}] default enabled state per channel
  Definition = Data.define(:key, :label, :description, :defaults)

  DEFINITIONS = {
    evidence_requested: Definition.new(
      key: :evidence_requested,
      label: "Feedback requested from you",
      description: "A colleague asks you to provide feedback for someone's assessment.",
      defaults: { in_app: true, slack: true, email: true }
    ),
    evidence_request_responded: Definition.new(
      key: :evidence_request_responded,
      label: "Your feedback request was answered",
      description: "Someone you asked has provided the feedback you requested.",
      defaults: { in_app: true, slack: false, email: false }
    ),
    evidence_request_declined: Definition.new(
      key: :evidence_request_declined,
      label: "Your feedback request was declined",
      description: "Someone you asked has declined to provide feedback.",
      defaults: { in_app: true, slack: false, email: false }
    ),
    evidence_request_reminder: Definition.new(
      key: :evidence_request_reminder,
      label: "Reminder about a feedback request",
      description: "A feedback request you haven't answered is going stale or coming due.",
      defaults: { in_app: true, slack: true, email: false }
    ),
    comment_reply: Definition.new(
      key: :comment_reply,
      label: "Reply to your comment",
      description: "Someone replies to a comment you posted on an assessment discussion.",
      defaults: { in_app: true, slack: true, email: false }
    ),
    assessment_commented: Definition.new(
      key: :assessment_commented,
      label: "New comment on your assessment",
      description: "Your manager or another participant comments on your assessment.",
      defaults: { in_app: true, slack: true, email: false }
    ),
    team_assessment_commented: Definition.new(
      key: :team_assessment_commented,
      label: "A report commented on their assessment",
      description: "Someone whose assessment you manage posts a comment on it.",
      defaults: { in_app: true, slack: true, email: false }
    ),
    bulk_enrollment_completed: Definition.new(
      key: :bulk_enrollment_completed,
      label: "Bulk cycle enrollment finished",
      description: "The background enrollment you started has completed, with its enrolled/skipped outcome.",
      defaults: { in_app: true, slack: false, email: false }
    ),
    framework_published: Definition.new(
      key: :framework_published,
      label: "Framework publish finished",
      description: "The framework version you asked to publish went live, or the publish was refused.",
      defaults: { in_app: true, slack: false, email: false }
    ),
    rating_revisit_requested: Definition.new(
      key: :rating_revisit_requested,
      label: "Calibration asked you to revisit a rating",
      description: "A calibration session asks you to take a second look at one of your ratings.",
      defaults: { in_app: true, slack: true, email: false }
    ),
    lens_alignment_started: Definition.new(
      key: :lens_alignment_started,
      label: "Alignment against another role started",
      description: "Your manager starts an alignment conversation about another role, sharing their ratings on it.",
      defaults: { in_app: true, slack: true, email: false }
    ),
    exploration_started: Definition.new(
      key: :exploration_started,
      label: "An exploration of another role started",
      description: "You or your manager share that you're exploring another role or level.",
      defaults: { in_app: true, slack: true, email: false }
    ),
    exploration_closed: Definition.new(
      key: :exploration_closed,
      label: "An exploration of another role closed",
      description: "An exploration you share with your manager or report is stopped, with what came of it.",
      defaults: { in_app: true, slack: false, email: false }
    )
  }.freeze

  # @return [Array<Definition>] every registered notification type
  def self.all
    DEFINITIONS.values
  end

  # @param key [Symbol, String]
  # @return [Definition, nil]
  def self.find(key)
    DEFINITIONS[key.to_sym]
  end

  # @param key [Symbol, String]
  # @return [Boolean] whether a type with this key is registered
  def self.exists?(key)
    DEFINITIONS.key?(key.to_sym)
  end

  # Resolve the effective enabled state for a (type, channel) given a user's
  # stored overrides. An explicit override wins; otherwise the registry
  # default applies. Unknown types/channels resolve to false (fail closed).
  #
  # @param overrides [Hash] the user's `notification_preferences` hash
  # @param type_key [Symbol, String]
  # @param channel [Symbol, String]
  # @return [Boolean]
  def self.enabled?(overrides, type_key, channel)
    type = find(type_key)
    return false if type.nil?
    return false unless CHANNELS.include?(channel.to_sym)

    override = overrides.to_h.dig(type_key.to_s, channel.to_s)
    return type.defaults.fetch(channel.to_sym, false) if override.nil?

    ActiveModel::Type::Boolean.new.cast(override) || false
  end
end
