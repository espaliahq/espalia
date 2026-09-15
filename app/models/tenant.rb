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
  validates :hris_config, store_model: true

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
end
