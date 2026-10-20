# frozen_string_literal: true

# A tenant's theme (ADR-23, #550): Default, a preset (Bento), or Custom, which
# starts from Default and takes the tenant's own values for the colour roles.
#
# Custom values reach the page as scheme-suffixed variables (`--tenant-brand`,
# `--tenant-brand-dark`) that `theme/roles.css` picks up, so the light/dark
# rule lives only in CSS. A role a tenant can set is one with such a hook there.
module Themeable
  extend ActiveSupport::Concern

  THEMES = %w[default bento custom].freeze
  PRESETS = %w[bento].freeze
  SCHEMES = %w[light dark].freeze
  HEX_COLOR_FORMAT = /\A#[0-9a-fA-F]{6}\z/

  # A preset is a whole theme, font included; a tenant's own font applies only under Custom.
  PRESET_FONT_URLS = {
    "bento" => "https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,200..800;1,200..800&display=swap"
  }.freeze

  ROLES_STYLESHEET = Rails.root.join("app/assets/tailwind/theme/roles.css")
  # Each role's Default value per scheme: the fallback its hook carries in roles.css.
  CUSTOM_ROLE_DEFAULTS = ROLES_STYLESHEET.read.scan(/var\(--tenant-([a-z-]+?)(-dark)?,\s*([^)]+?)\s*\)/)
    .each_with_object({}) { |(role, dark, value), defaults| (defaults[role] ||= {})[dark ? "dark" : "light"] = value }
    .freeze
  CUSTOM_ROLES = CUSTOM_ROLE_DEFAULTS.keys.freeze

  # Each theme's navbar, for the browser's own chrome. Default's are also the
  # web-app manifest's `theme_color` (static, so never per-tenant; see
  # docs/guidelines/app-icons.md) and the nav-surface defaults in roles.css.
  DEFAULT_NAV_BG_COLOR = "#32c8c8"
  DEFAULT_NAV_BG_COLOR_DARK = "#1a1a2e"
  NAV_SURFACES = {
    "default" => { "light" => DEFAULT_NAV_BG_COLOR, "dark" => DEFAULT_NAV_BG_COLOR_DARK },
    "bento" => { "light" => "#ffffff", "dark" => "#0a0d12" }
  }.freeze

  included do
    attribute :theme, :string, default: "default"
    store_accessor :settings, :font_family

    normalizes :custom_theme, with: ->(value) { Themeable.compact_custom_theme(value) }

    validates :theme, inclusion: { in: THEMES }
    validates :font_family, format: { with: /\A[a-zA-Z0-9\s]+\z/ }, allow_blank: true
    validate :custom_theme_holds_known_roles_and_hex_colours
  end

  class_methods do
    # The colour the browser should paint its own chrome (address bar, title
    # bar, task switcher) for a page of this tenant: its theme's navbar.
    #
    # @param tenant [Tenant, nil]
    # @param scheme [Symbol] :light or :dark
    # @return [String] a hex colour
    def browser_theme_color(tenant, scheme)
      tenant&.nav_surface(scheme) || NAV_SURFACES.dig("default", scheme.to_s)
    end
  end

  # Blank values and roles with nothing left are dropped, so a stored role
  # always means "the tenant chose this", and a blank one falls back to Default.
  #
  # @param value [Hash, nil]
  # @return [Hash, Object] the cleaned hash, or the value untouched when it isn't one
  def self.compact_custom_theme(value)
    return value unless value.respond_to?(:to_h)

    value.to_h.each_with_object({}) do |(role, schemes), theme|
      next theme[role.to_s] = schemes unless schemes.respond_to?(:to_h)

      kept = schemes.to_h.transform_keys(&:to_s).reject { |_, hex| hex.blank? }
      theme[role.to_s] = kept if kept.any?
    end
  end

  # @return [Boolean]
  def custom_theme?
    theme == "custom"
  end

  # @return [String, nil] the preset for `<html data-theme>`; Default and Custom set none
  def theme_preset
    theme if PRESETS.include?(theme)
  end

  # The tenant's own value for a role, or nil where Default's applies.
  #
  # @param role [String] a role name from {CUSTOM_ROLES}, e.g. "brand"
  # @param scheme [Symbol, String] :light or :dark
  # @return [String, nil]
  def custom_role(role, scheme)
    custom_theme.dig(role.to_s, scheme.to_s) if custom_theme?
  end

  # @param scheme [Symbol, String] :light or :dark
  # @return [String] this theme's navbar colour
  def nav_surface(scheme)
    custom_role("nav-surface", scheme) ||
      NAV_SURFACES.fetch(theme, NAV_SURFACES["default"]).fetch(scheme.to_s)
  end

  # The variables `#tenant-theme` injects on `:root`: a Custom theme's role
  # values and font. Presets and Default ship as static CSS, so they get none.
  #
  # @return [Hash{String => String}]
  def theme_css_variables
    return {} unless custom_theme?

    vars = custom_theme.each_with_object({}) do |(role, schemes), result|
      result["--tenant-#{role}"] = schemes["light"] if schemes["light"]
      result["--tenant-#{role}-dark"] = schemes["dark"] if schemes["dark"]
    end
    vars["--font-sans"] = "\"#{font_family}\", ui-sans-serif, system-ui, sans-serif" if font_family.present?
    vars
  end

  # @return [String, nil] the Google Fonts URL for a Custom theme's font
  def google_font_url
    return unless custom_theme? && font_family.present?

    family = font_family.gsub(" ", "+")
    "https://fonts.googleapis.com/css2?family=#{family}:wght@300;400;500;600;700&display=swap"
  end

  private

  # @return [void]
  def custom_theme_holds_known_roles_and_hex_colours
    unless custom_theme.is_a?(Hash)
      errors.add(:custom_theme, "must map role names to light and dark colours")
      return
    end

    custom_theme.each do |role, schemes|
      next errors.add(:custom_theme, "has an unknown role: #{role}") unless CUSTOM_ROLES.include?(role)
      next errors.add(:custom_theme, "#{role} must map light and dark to colours") unless schemes.is_a?(Hash)

      schemes.each do |scheme, hex|
        next errors.add(:custom_theme, "#{role} has an unknown scheme: #{scheme}") unless SCHEMES.include?(scheme)

        errors.add(:custom_theme, "#{role} #{scheme} must be a hex colour like #32c8c8") unless HEX_COLOR_FORMAT.match?(hex.to_s)
      end
    end
  end
end
