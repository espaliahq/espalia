# frozen_string_literal: true

# A tenant's theme becomes a choice of Default, Bento or Custom, and Custom
# stores colour-role values rather than the five legacy settings (#550).
#
# Every tenant with theme settings today becomes Custom: primary → brand, nav
# background → nav-surface, each light and dark; the font stays in
# `settings`. Secondary and nav text are dropped: hovers derive from the brand
# and the contrast helper picks the nav text, so `down` cannot restore them.
# It restores primary and nav background, which is everything that still
# renders.
class StoreTenantThemeAsPresetOrCustomRoles < ActiveRecord::Migration[8.1]
  class TenantRow < ActiveRecord::Base
    self.table_name = "tenants"
  end

  ROLE_SETTINGS = {
    "brand" => %w[primary_color primary_color_dark],
    "nav-surface" => %w[nav_bg_color nav_bg_color_dark]
  }.freeze
  DROPPED_SETTINGS = %w[secondary_color secondary_color_dark nav_fg_color nav_fg_color_dark].freeze
  THEME_SETTINGS = (ROLE_SETTINGS.values.flatten + DROPPED_SETTINGS + %w[font_family]).freeze

  def up
    add_column :tenants, :theme, :string, default: "default", null: false
    add_column :tenants, :custom_theme, :jsonb, default: {}, null: false
    TenantRow.reset_column_information

    TenantRow.find_each do |tenant|
      next unless THEME_SETTINGS.any? { |key| tenant.settings[key].present? }

      tenant.update_columns(
        theme: "custom",
        custom_theme: custom_theme_from(tenant.settings),
        settings: tenant.settings.except(*ROLE_SETTINGS.values.flatten, *DROPPED_SETTINGS)
      )
    end
  end

  def down
    TenantRow.where(theme: "custom").find_each do |tenant|
      restored = ROLE_SETTINGS.each_with_object({}) do |(role, (light_key, dark_key)), settings|
        values = tenant.custom_theme.fetch(role, {})
        settings[light_key] = values["light"] if values["light"].present?
        settings[dark_key] = values["dark"] if values["dark"].present?
      end
      tenant.update_columns(settings: tenant.settings.merge(restored))
    end

    remove_column :tenants, :custom_theme
    remove_column :tenants, :theme
  end

  private

  # @return [Hash{String => Hash{String => String}}]
  def custom_theme_from(settings)
    ROLE_SETTINGS.each_with_object({}) do |(role, (light_key, dark_key)), theme|
      values = { "light" => settings[light_key].presence, "dark" => settings[dark_key].presence }.compact
      theme[role] = values if values.any?
    end
  end
end
