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
      label: "Evidence requested from you",
      description: "A colleague asks you to provide evidence for someone's assessment.",
      defaults: { in_app: true, slack: true, email: true }
    ),
    evidence_request_responded: Definition.new(
      key: :evidence_request_responded,
      label: "Your evidence request was answered",
      description: "Someone you asked has provided the evidence you requested.",
      defaults: { in_app: true, slack: false, email: false }
    ),
    evidence_request_declined: Definition.new(
      key: :evidence_request_declined,
      label: "Your evidence request was declined",
      description: "Someone you asked has declined to provide evidence.",
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
