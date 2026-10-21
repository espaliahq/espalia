# frozen_string_literal: true

# Represents an organisation using GrowthOS.
#
# Tenants are the root of the multi-tenancy model. All user and domain data
# is scoped to a tenant via acts_as_tenant row-level isolation.
#
# @example
#   tenant = Tenant.create!(name: "ACME Corp", slug: "acme-corp")
#
class Tenant < ApplicationRecord
  FEEDBACK_EXCHANGE_MIN_SECRET_LENGTH = 32
  HEX_COLOR_FORMAT = /\A#[0-9a-fA-F]{6}\z/

  # The navbar colours the app ships with (`--color-nav-bg` in
  # app/assets/tailwind/application.css). Also the fallback browser
  # `theme-color`, and the `theme_color` of the (static, so never per-tenant)
  # web-app manifest — see docs/guidelines/app-icons.md.
  DEFAULT_NAV_BG_COLOR = "#32c8c8"
  DEFAULT_NAV_BG_COLOR_DARK = "#1a1a2e"

  has_many :tenant_users, dependent: :destroy
  has_many :users, through: :tenant_users
  has_many :people, dependent: :destroy

  attribute :hris_config, HrisConfig.to_type, default: -> { HrisConfig.new }
  serialize :hris_credentials, coder: JSON
  encrypts :hris_credentials

  # The model behind AI features. The config is plain settings; the credentials
  # are encrypted JSON: { api_key: }.
  attribute :ai_config, AiModelConfig.to_type, default: -> { AiModelConfig.new }
  serialize :ai_credentials, coder: JSON
  encrypts :ai_credentials

  # Feedback exchange with a peer system. The config is plain settings; the
  # credentials are the two signing secrets, encrypted JSON:
  # { outbound_secret:, inbound_secret:, previous_inbound_secret:, previous_rotated_at: }.
  attribute :feedback_exchange_config, FeedbackExchangeConfig.to_type, default: -> { FeedbackExchangeConfig.new }
  serialize :feedback_exchange_credentials, coder: JSON
  encrypts :feedback_exchange_credentials

  # Slack bot credentials for this workspace, set when a tenant admin installs
  # the GrowthOS Slack app. Encrypted JSON: { bot_token:, team_name:, installed_by: }.
  serialize :slack_credentials, coder: JSON
  encrypts :slack_credentials

  store_accessor :settings,
    :primary_color, :primary_color_dark,
    :secondary_color, :secondary_color_dark,
    :nav_bg_color, :nav_bg_color_dark,
    :nav_fg_color, :nav_fg_color_dark,
    :font_family

  # Whether feedback recorded here is sent to the model for placement
  # suggestions. Off until the data-handling decision (plan D2) is made, and
  # never switched on by seeds. The switch lives in {#ai_config}; a tenant
  # that was switched on under the earlier `settings` key stays on until its
  # admin saves the AI model card (see {#legacy_evidence_suggestions_enabled?}).
  #
  # @return [Boolean]
  def evidence_suggestions_enabled?
    ai_config.suggestions_enabled? || legacy_evidence_suggestions_enabled?
  end

  # One-release reader for the switch and model id that placement suggestions
  # kept in `settings` before the AI model card existed. Remove with the
  # Anthropic key fallback in {#ai_api_key} once every tenant has been saved
  # through the card.
  #
  # @return [Boolean]
  def legacy_evidence_suggestions_enabled?
    ActiveModel::Type::Boolean.new.cast(settings&.dig("evidence_suggestions_enabled")) || false
  end

  # @return [String, nil]
  def legacy_evidence_suggestions_model
    settings&.dig("evidence_suggestions_model").presence
  end

  # {#ai_config} with the legacy switch and model id folded in, which is what
  # requests are built from and what the card's form starts from.
  #
  # @return [AiModelConfig]
  def effective_ai_config
    AiModelConfig.new(ai_config.attributes.merge(
      "suggestions_enabled" => evidence_suggestions_enabled?,
      "model" => ai_config.model.presence || legacy_evidence_suggestions_model
    ))
  end

  # The AI model's API key wrapped so no accessor can print it.
  #
  # @return [AiModelCredentials]
  def ai_secrets
    AiModelCredentials.new(ai_credentials)
  end

  # The key requests are made with: the one stored through the AI model card,
  # else, for a tenant still on the legacy switch, the deployment's Anthropic
  # key from the credentials file as before.
  #
  # @return [String, nil]
  def ai_api_key
    ai_secrets.api_key || legacy_deployment_key
  end

  # Save the AI model settings and key in one write. Unlisted settings keep
  # their value, and a blank key keeps the stored one, so a form that never
  # echoes the key can be saved without retyping it.
  #
  # Two things refuse a save outright, because either would otherwise fail
  # silently later: pointing a stored key at a different provider or address
  # without entering it again (the key would go to a host its owner never
  # chose), and switching suggestions on with no key at all.
  #
  # Saving through the card is the move off the legacy `settings` switch: the
  # old keys are dropped, so the card's switch is the only one left, and so is
  # the deployment-wide key those tenants used.
  #
  # @param settings [Hash] AiModelConfig attributes to change
  # @param api_key [String, nil]
  # @raise [ActiveRecord::RecordInvalid] when the settings do not validate
  # @return [Boolean]
  def update_ai_model!(settings: {}, api_key: nil)
    errors.clear
    with_lock do
      previous = ai_config
      credentials = (ai_credentials.is_a?(Hash) ? ai_credentials : {}).dup
      stored_key = credentials["api_key"].presence
      new_key = api_key.strip.presence if api_key.is_a?(String)
      on_legacy_key = legacy_evidence_suggestions_enabled? && stored_key.nil?
      credentials["api_key"] = new_key if new_key

      assign_attributes(
        ai_config: AiModelConfig.new(previous.attributes.merge(settings.stringify_keys)),
        ai_credentials: credentials.presence,
        settings: self.settings.to_h.except("evidence_suggestions_enabled", "evidence_suggestions_model")
      )
      reject_unsafe_ai_model!(previous: previous, stored_key: stored_key, new_key: new_key, on_legacy_key: on_legacy_key)
      save!
    end
  end

  # The word this tenant uses for each performance state. The state itself
  # is scoring policy and stays internal; the word is culture (#415). A
  # blank value falls back to the shipped default — see
  # {Views::Assessments::StateLabels}, the one reader.
  STATE_LABEL_ATTRIBUTES = %i[
    underperforming_label progressing_label performing_label mastering_label eligible_label
  ].freeze

  # Long enough for "Exceeding expectations", short enough to stay a badge:
  # every surface renders these as an eyebrow beside a number, never in the
  # middle of a sentence.
  STATE_LABEL_MAX_LENGTH = 24

  translates(*STATE_LABEL_ATTRIBUTES)

  # `normalizes` only reaches real AR attributes, and json_translate's are
  # methods over a jsonb column — so the strip is a callback. Without it a
  # label of spaces is neither blank (the fallback never fires) nor a word
  # (it renders as an empty badge).
  before_validation :strip_state_labels

  normalizes :slug, with: ->(s) { s.downcase.strip.gsub(/[^a-z0-9-]/, "-").gsub(/-+/, "-").delete_prefix("-").delete_suffix("-") }


  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "must contain only lowercase letters, numbers, and dashes" }
  validates :primary_color, :primary_color_dark,
    :secondary_color, :secondary_color_dark,
    :nav_bg_color, :nav_bg_color_dark,
    :nav_fg_color, :nav_fg_color_dark,
    format: { with: HEX_COLOR_FORMAT }, allow_blank: true
  validates :font_family, format: { with: /\A[a-zA-Z0-9\s]+\z/ }, allow_blank: true
  validates(*STATE_LABEL_ATTRIBUTES, length: { maximum: STATE_LABEL_MAX_LENGTH }, allow_blank: true)
  validates :hris_config, store_model: true
  validates :ai_config, store_model: true
  validates :feedback_exchange_config, store_model: true
  before_validation :sync_feedback_exchange_key_ids, if: :feedback_exchange_credentials_changed?
  validate :feedback_exchange_inbound_secret_is_ours, if: :feedback_exchange_credentials_changed?
  validate :feedback_exchange_secrets_are_strong, if: :feedback_exchange_credentials_changed?

  # The colour the browser should paint its own chrome (address bar, title
  # bar, task switcher) for a page of this tenant: the tenant's navbar
  # colour, or the app default when none is set.
  #
  # @param tenant [Tenant, nil]
  # @param scheme [Symbol] :light or :dark
  # @return [String] a hex colour
  def self.browser_theme_color(tenant, scheme)
    if scheme == :dark
      tenant&.nav_bg_color_dark.presence || DEFAULT_NAV_BG_COLOR_DARK
    else
      tenant&.nav_bg_color.presence || DEFAULT_NAV_BG_COLOR
    end
  end

  # Returns CSS variable overrides for light mode.
  #
  # @return [Hash{String => String}]
  def theme_css_variables_light
    vars = {}
    vars["--color-primary"] = primary_color if primary_color.present?
    vars["--color-secondary"] = secondary_color if secondary_color.present?
    vars["--color-nav-bg"] = nav_bg_color if nav_bg_color.present?
    vars["--color-nav-fg"] = nav_fg_color if nav_fg_color.present?
    vars["--font-sans"] = "\"#{font_family}\", ui-sans-serif, system-ui, sans-serif" if font_family.present?
    vars
  end

  # Returns CSS variable overrides for dark mode.
  #
  # @return [Hash{String => String}]
  def theme_css_variables_dark
    vars = {}
    vars["--color-primary"] = primary_color_dark if primary_color_dark.present?
    vars["--color-secondary"] = secondary_color_dark if secondary_color_dark.present?
    vars["--color-nav-bg"] = nav_bg_color_dark if nav_bg_color_dark.present?
    vars["--color-nav-fg"] = nav_fg_color_dark if nav_fg_color_dark.present?
    vars["--font-sans"] = "\"#{font_family}\", ui-sans-serif, system-ui, sans-serif" if font_family.present?
    vars
  end

  # Returns the Google Fonts URL for the tenant's custom font, if set.
  #
  # @return [String, nil]
  def google_font_url
    return unless font_family.present?

    family = font_family.gsub(" ", "+")
    "https://fonts.googleapis.com/css2?family=#{family}:wght@300;400;500;600;700&display=swap"
  end

  # The feedback exchange's signing secrets, wrapped so no accessor can print a value.
  #
  # @return [FeedbackExchangeSecrets]
  def feedback_exchange_secrets
    FeedbackExchangeSecrets.new(feedback_exchange_credentials)
  end

  # Save the feedback exchange settings and secrets in one write. Unlisted settings
  # keep their value. A blank secret keeps the stored one, so a form that never echoes
  # a secret can be saved without retyping it. Replacing the inbound secret keeps the
  # old one as the previous secret, which still verifies for 24 hours (protocol §6).
  #
  # The row is locked and reloaded first, so sync state a job wrote since this tenant
  # was loaded (the cursors, `last_synced_at`) is kept, not overwritten.
  #
  # @param settings [Hash] FeedbackExchangeConfig attributes to change
  # @param outbound_secret [String, nil]
  # @param inbound_secret [String, nil]
  # @raise [ActiveRecord::RecordInvalid] when the settings do not validate
  # @return [Boolean]
  def update_feedback_exchange!(settings: {}, outbound_secret: nil, inbound_secret: nil)
    # A save that failed validation leaves its assignments behind, and a locked
    # reload refuses unsaved changes: start from what is stored.
    restore_attributes(%w[feedback_exchange_config feedback_exchange_credentials inbound_key_id previous_inbound_key_id])
    with_lock do
      credentials = (feedback_exchange_credentials.is_a?(Hash) ? feedback_exchange_credentials : {}).dup
      credentials["outbound_secret"] = outbound_secret.strip if outbound_secret.present?
      if inbound_secret.present? && inbound_secret.strip != credentials["inbound_secret"]
        if credentials["inbound_secret"].present?
          credentials["previous_inbound_secret"] = credentials["inbound_secret"]
          credentials["previous_rotated_at"] = Time.current.iso8601
        end
        credentials["inbound_secret"] = inbound_secret.strip
      end

      assign_attributes(
        feedback_exchange_config: FeedbackExchangeConfig.new(feedback_exchange_config.attributes.merge(settings.stringify_keys)),
        feedback_exchange_credentials: credentials.presence
      )
      save!
    end
  end

  # @return [Boolean] whether this tenant has a usable Slack connection
  def slack_connected?
    slack_bot_token.present?
  end

  # @return [String, nil] the Slack bot token, or nil when not connected
  def slack_bot_token
    slack_credentials.is_a?(Hash) ? slack_credentials["bot_token"].presence : nil
  end

  # @return [String, nil] the connected workspace's display name
  def slack_team_name
    slack_credentials.is_a?(Hash) ? slack_credentials["team_name"] : nil
  end

  # Record a completed Slack install. Persists the encrypted bot token and the
  # plain team id (used for inbound event routing later).
  #
  # @param bot_token [String]
  # @param team_id [String]
  # @param team_name [String, nil]
  # @param installed_by [String, nil] Person id of the installing admin
  # @return [Boolean]
  def connect_slack!(bot_token:, team_id:, team_name: nil, installed_by: nil)
    transaction do
      update!(
        slack_team_id: team_id,
        slack_credentials: { "bot_token" => bot_token, "team_name" => team_name, "installed_by" => installed_by }
      )
      # A reconnect may point at a different workspace, where the cached
      # per-user Slack ids no longer resolve — clear them so they re-resolve.
      tenant_users.where.not(slack_user_id: nil).update_all(slack_user_id: nil)
    end
    true
  end

  # Remove the Slack connection. Cached per-user Slack ids are cleared too so a
  # reconnect to a different workspace re-resolves identities.
  #
  # @return [void]
  def disconnect_slack!
    transaction do
      update!(slack_credentials: nil, slack_team_id: nil)
      tenant_users.where.not(slack_user_id: nil).update_all(slack_user_id: nil)
    end
  end

  private

  # The key ids the verifier looks a tenant up by, derived from the stored secrets.
  def sync_feedback_exchange_key_ids
    secrets = feedback_exchange_secrets
    self.inbound_key_id = secrets.inbound_secret && FeedbackExchange::Signature.key_id(secrets.inbound_secret)
    self.previous_inbound_key_id = secrets.previous_inbound_secret &&
                                   FeedbackExchange::Signature.key_id(secrets.previous_inbound_secret)
  end

  # Each signing secret is long enough to be random, and the two differ: protocol §6
  # asks for one secret per direction.
  def feedback_exchange_secrets_are_strong
    secrets = feedback_exchange_secrets
    { "Outbound secret" => secrets.outbound_secret, "Inbound secret" => secrets.inbound_secret }.each do |label, value|
      next if value.nil? || value.length >= FEEDBACK_EXCHANGE_MIN_SECRET_LENGTH

      errors.add(:base, "#{label} must be at least #{FEEDBACK_EXCHANGE_MIN_SECRET_LENGTH} characters. " \
                        "Generate one with `openssl rand -hex 32`.")
    end
    return unless secrets.outbound_secret && secrets.outbound_secret == secrets.inbound_secret

    errors.add(:base, "The outbound and inbound secrets must differ: use one secret per direction.")
  end

  # An inbound secret identifies the tenant a request is for, so two tenants must
  # not share one, current or previous.
  def feedback_exchange_inbound_secret_is_ours
    ids = [ inbound_key_id, previous_inbound_key_id ].compact
    return if ids.empty?

    taken = Tenant.where.not(id: id).where("inbound_key_id IN (:ids) OR previous_inbound_key_id IN (:ids)", ids: ids)
    errors.add(:base, "That inbound secret is already in use by another workspace. Use a new random secret.") if taken.exists?
  end

  # @return [void]
  def strip_state_labels
    STATE_LABEL_ATTRIBUTES.each do |attribute|
      value = public_send(attribute)
      next unless value.is_a?(String) && value != value.strip

      public_send(:"#{attribute}=", value.strip)
    end
  end

  # The deployment's Anthropic key goes only to the Anthropic API itself: a
  # tenant-chosen address must never receive a key its owner did not give.
  #
  # @return [String, nil]
  def legacy_deployment_key
    return unless legacy_evidence_suggestions_enabled?
    return unless ai_config.anthropic? && ai_config.normalized_base_url.nil?

    Rails.application.credentials.dig(:anthropic, :api_key).presence
  end

  # @raise [ActiveRecord::RecordInvalid]
  def reject_unsafe_ai_model!(previous:, stored_key:, new_key:, on_legacy_key:)
    return unless ai_config.valid? # save! reports what is wrong with the settings first

    moved = [ previous.provider, previous.normalized_base_url ] != [ ai_config.provider, ai_config.normalized_base_url ]
    if stored_key && !new_key && moved
      errors.add(:base, "Enter the API key again. The stored one is only sent to the provider and address it was saved for.")
    elsif ai_config.suggestions_enabled? && !(new_key || stored_key)
      legacy = on_legacy_key ? " This workspace has been using the deployment's key, which the AI model card does not fall back to." : ""
      errors.add(:base, "Add an API key to switch suggestions on.#{legacy}")
    end
    raise ActiveRecord::RecordInvalid, self if errors.any?
  end
end
