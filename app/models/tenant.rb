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

  has_many :tenant_users, dependent: :destroy
  has_many :users, through: :tenant_users
  has_many :people, dependent: :destroy

  store_accessor :settings, :primary_color, :secondary_color, :nav_bg_color, :nav_fg_color, :font_family

  normalizes :slug, with: ->(s) { s.downcase.strip.gsub(/[^a-z0-9-]/, "-").gsub(/-+/, "-").delete_prefix("-").delete_suffix("-") }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "must contain only lowercase letters, numbers, and dashes" }
  validates :primary_color, format: { with: HEX_COLOR_FORMAT }, allow_blank: true
  validates :secondary_color, format: { with: HEX_COLOR_FORMAT }, allow_blank: true
  validates :nav_bg_color, format: { with: HEX_COLOR_FORMAT }, allow_blank: true
  validates :nav_fg_color, format: { with: HEX_COLOR_FORMAT }, allow_blank: true
  validates :font_family, format: { with: /\A[a-zA-Z0-9\s]+\z/ }, allow_blank: true

  # Returns CSS variable overrides for tenant-specific theme colours.
  #
  # Only includes variables for colours that have been set. When empty,
  # the defaults from TailwindCSS @theme apply.
  #
  # @return [Hash{String => String}]
  def theme_css_variables
    vars = {}
    vars["--color-primary"] = primary_color if primary_color.present?
    vars["--color-secondary"] = secondary_color if secondary_color.present?
    vars["--color-nav-bg"] = nav_bg_color if nav_bg_color.present?
    vars["--color-nav-fg"] = nav_fg_color if nav_fg_color.present?
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
end
