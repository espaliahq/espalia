# frozen_string_literal: true

# Tenant theme editor — color pickers for brand palette + a font input.
# Live preview is wired up via the `theme-live-preview` Stimulus
# controller: every `input` event sets a CSS variable on
# `document.documentElement` so the running page repaints as the
# admin drags color pickers.
#
class Views::Tenant::Theme::EditView < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::FormWith

  # One row per color concept; each carries a light + dark sub-control
  # so admins see the pair together and the layout reads top-to-bottom
  # without crossed labels.
  COLOR_GROUPS = [
    {
      label: "Primary",
      var: "--color-primary",
      light: { attr: :primary_color,        default: "#32c8c8" },
      dark:  { attr: :primary_color_dark,   default: "#5ee0e0" }
    },
    {
      label: "Secondary",
      var: "--color-secondary",
      light: { attr: :secondary_color,      default: "#079191" },
      dark:  { attr: :secondary_color_dark, default: "#0ababa" }
    },
    {
      label: "Nav background",
      var: "--color-nav-bg",
      light: { attr: :nav_bg_color,         default: "#32c8c8" },
      dark:  { attr: :nav_bg_color_dark,    default: "#1a1a2e" }
    },
    {
      label: "Nav text",
      var: "--color-nav-fg",
      light: { attr: :nav_fg_color,         default: "#ffffff" },
      dark:  { attr: :nav_fg_color_dark,    default: "#e2e8f0" }
    }
  ].freeze

  # @param tenant [Tenant]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(tenant:, user:, current_tenant:, tenants: [])
    @tenant = tenant
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::TenantAdminLayout.new(
      active_section: :theme,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Theme",
        subtitle: "Brand colors and typography. Changes preview live; click Save to persist."
      )

      form_with(
        url: tenant_theme_path, method: :patch, scope: :tenant,
        data: { controller: "theme-live-preview" },
        class: "space-y-6"
      ) do |form|
        colors_card(form)
        typography_card(form)
        dark_mode_note
        actions(form)
      end
    end
  end

  private

  def colors_card(form)
    render Components::Kit::Card.new(title: "Brand colors") do |card|
      card.body do
        # Column headers — only on sm+ to anchor the light/dark grouping.
        div(class: "hidden sm:grid sm:grid-cols-[1fr_auto_auto] gap-x-6 gap-y-2 " \
                   "text-xs font-medium uppercase tracking-wide " \
                   "text-gray-400 dark:text-gray-500 pb-2 " \
                   "border-b border-gray-200 dark:border-gray-700") do
          span { "" }
          span(class: "text-center min-w-[5rem]") { "Light" }
          span(class: "text-center min-w-[5rem]") { "Dark" }
        end

        div(class: "divide-y divide-gray-200 dark:divide-gray-700") do
          COLOR_GROUPS.each { |group| color_group_row(form, group) }
        end
      end
    end
  end

  def color_group_row(form, group)
    div(class: "grid grid-cols-1 sm:grid-cols-[1fr_auto_auto] gap-x-6 gap-y-3 py-4 items-center") do
      div(class: "min-w-0") do
        span(class: "block text-sm font-medium text-gray-900 dark:text-white") { group[:label] }
      end
      color_picker(form, group[:var], group[:light], mode: :light)
      color_picker(form, group[:var], group[:dark],  mode: :dark)
    end
  end

  def color_picker(form, var, slot, mode:)
    current = @tenant.public_send(slot[:attr]).presence || slot[:default]

    div(class: "flex items-center gap-2 sm:justify-self-center") do
      span(class: "sm:hidden text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400 w-12") do
        mode.to_s.capitalize
      end
      form.color_field slot[:attr],
        value: current,
        aria: { label: "#{form.object_name} #{slot[:attr]}" },
        class: "h-9 w-12 rounded border border-gray-300 dark:border-gray-600 cursor-pointer",
        data: {
          theme_live_preview_target: "field",
          theme_live_preview_var_param: var,
          theme_live_preview_mode_param: mode.to_s,
          theme_live_preview_default_param: current,
          action: "input->theme-live-preview#apply"
        }
      span(class: "text-xs font-mono text-gray-500 dark:text-gray-400 w-16 truncate") { current }
    end
  end

  def typography_card(form)
    current_font = @tenant.font_family.presence || ""

    render Components::Kit::Card.new(title: "Typography") do |card|
      card.body do
        form.label :font_family, "Font family",
                   class: "block text-sm font-medium text-gray-700 dark:text-gray-300"
        p(class: "text-xs text-gray-500 dark:text-gray-400 mt-0.5 mb-2") do
          plain "Google Fonts family name (e.g. \"Inter\", \"Roboto\"). Leave blank for the default."
        end
        form.text_field :font_family,
          value: current_font,
          placeholder: "InterVariable",
          class: "block w-full max-w-sm rounded-md border-gray-300 dark:border-gray-600 " \
                 "dark:bg-gray-700 dark:text-white shadow-xs focus:border-primary focus:ring-primary",
          data: {
            theme_live_preview_target: "field",
            theme_live_preview_var_param: "--font-sans",
            theme_live_preview_mode_param: "both",
            theme_live_preview_default_param: current_font,
            action: "input->theme-live-preview#apply"
          }
      end
    end
  end

  def dark_mode_note
    p(class: "text-xs text-gray-500 dark:text-gray-400 px-1") do
      plain "Dark-mode previews are visible only when your OS is in dark mode."
    end
  end

  def actions(form)
    div(class: "flex justify-end gap-3") do
      button(
        type: "button",
        class: "px-4 py-2 rounded-md border border-gray-300 dark:border-gray-600 " \
               "text-sm text-gray-700 dark:text-gray-300 " \
               "hover:bg-gray-100 dark:hover:bg-gray-800",
        data: { action: "theme-live-preview#revert" }
      ) { "Cancel" }
      form.submit "Save",
        class: "px-4 py-2 rounded-md bg-primary text-white text-sm font-medium " \
               "hover:bg-secondary focus:outline-hidden focus:ring-2 focus:ring-primary " \
               "focus:ring-offset-2 cursor-pointer"
    end
  end
end
