# frozen_string_literal: true

# Tenant theme editor: choose Default, Bento or Custom, and Custom's colours and font.
# Each choice shows a framed preview in light and dark (`PreviewView`); the
# `theme-live-preview` Stimulus controller repaints the page and Custom's frames as the
# admin picks, and Cancel puts everything back.
class Views::Tenant::Theme::EditView < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::FormWith

  THEMES = [
    { value: "default", label: "Default", description: "GrowthOS's own teal." },
    { value: "bento", label: "Bento", description: "The Bento design system: lime, with Plus Jakarta Sans." },
    { value: "custom", label: "Custom", description: "Default, with your own brand, navbar and font." }
  ].freeze

  # How the page names each role in Tenant::CUSTOM_ROLES. The element is where Custom's
  # preview shows the contrast helper's text for the role, and `text` names it. `shade`
  # names the element's fill when CSS darkens the colour for it.
  ROLE_COPY = {
    "brand" => {
      label: "Brand", element: "[data-theme-preview-button]", text: "button text",
      shade: "Buttons use a darker shade",
      hint: "The main button and highlights."
    },
    "nav-surface" => {
      label: "Navbar", element: "nav", text: "text",
      hint: "The bar across the top of every page."
    }
  }.freeze

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
    render Components::Shell::TenantAdminLayout.new(
      active_section: :theme,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Theme",
        subtitle: "How GrowthOS looks for everyone here. Changes preview live; Save to keep them."
      )

      form_with(
        url: tenant_theme_path, method: :patch, scope: :tenant,
        data: { controller: "theme-live-preview" },
        class: "space-y-6"
      ) do |form|
        theme_choice
        custom_controls(form)
        scheme_note
        actions
      end
    end
  end

  private

  def theme_choice
    render Components::Kit::Card.new(title: "Theme", heading_level: :h2) do |card|
      card.body do
        fieldset do
          legend(class: "sr-only") { "Theme" }
          div(class: "grid gap-4 xl:grid-cols-3") do
            THEMES.each { |theme| theme_option(theme) }
          end
        end
      end
    end
  end

  def theme_option(theme)
    label(
      class: "flex min-w-0 cursor-pointer flex-col gap-3 rounded-lg border border-default p-3 " \
             "hover:bg-default-hover has-checked:border-strong has-checked:ring-1 has-checked:ring-inset " \
             "has-checked:ring-focus"
    ) do
      div(class: "flex items-start gap-3") do
        input(
          type: "radio", name: "tenant[theme]", value: theme[:value],
          checked: @tenant.theme == theme[:value],
          class: "#{Components::Kit::Field::RADIO} mt-0.5",
          aria: { describedby: "theme-#{theme[:value]}-description" },
          data: { theme_live_preview_target: "theme", action: "theme-live-preview#chooseTheme" }
        )
        div(class: "min-w-0") do
          span(class: "block text-sm font-semibold text-default") { theme[:label] }
          span(id: "theme-#{theme[:value]}-description", class: "block text-sm text-muted") { theme[:description] }
        end
      end
      div(class: "grid grid-cols-2 gap-2") do
        Tenant::SCHEMES.each { |scheme| preview_frame(theme, scheme) }
      end
    end
  end

  # Drawn at a phone's width and scaled to fit by the controller, so every frame shows the same layout.
  def preview_frame(theme, scheme)
    figure(class: "min-w-0") do
      div(class: "relative aspect-[3/2] overflow-hidden rounded-md border border-default") do
        iframe(
          src: preview_tenant_theme_path(theme_name: theme[:value], colour_scheme: scheme),
          title: "#{theme[:label]} theme, #{scheme}",
          tabindex: "-1",
          aria: { hidden: "true" },
          class: "pointer-events-none absolute top-0 left-0 h-[240px] w-[360px] origin-top-left border-0",
          data: {
            theme_live_preview_target: "frame", theme: theme[:value], scheme: scheme,
            action: "load->theme-live-preview#frameLoaded"
          }
        )
      end
      figcaption(class: "mt-1 text-xs text-muted") { scheme.capitalize }
    end
  end

  def custom_controls(form)
    custom = @tenant.custom_theme?

    fieldset(hidden: !custom, disabled: !custom, data: { theme_live_preview_target: "custom" }) do
      render Components::Kit::Card.new(title: "Custom theme", heading_level: :h2) do |card|
        card.body do
          p(class: "text-sm text-muted") do
            "Pick each colour for light and for dark. Text on it is black or white, whichever reads better."
          end
          div(class: "mt-4 divide-y divide-default border-t border-default") do
            Tenant::CUSTOM_ROLES.each { |role| role_row(custom_role(role)) }
          end
          font_field(form)
        end
      end
    end
  end

  # A role roles.css gained before this page named it still gets its pickers.
  def custom_role(role)
    { role:, label: role.tr("-", " ").capitalize, **ROLE_COPY.fetch(role, {}) }
  end

  def role_row(role)
    div(class: "grid grid-cols-1 items-start gap-x-6 gap-y-3 py-4 sm:grid-cols-[1fr_auto_auto]") do
      div(class: "min-w-0") do
        span(class: "block text-sm font-medium text-default") { role[:label] }
        span(class: "block text-sm text-muted") { role[:hint] }
      end
      Tenant::SCHEMES.each { |scheme| color_picker(role, scheme) }
    end
  end

  def color_picker(role, scheme)
    current = @tenant.custom_theme.dig(role[:role], scheme) || Tenant::CUSTOM_ROLE_DEFAULTS.dig(role[:role], scheme)
    readout_id = "theme-#{role[:role]}-#{scheme}-readout"

    div(class: "flex items-center gap-3") do
      input(
        type: "color",
        name: "tenant[custom_theme][#{role[:role]}][#{scheme}]",
        value: current,
        aria: { label: "#{role[:label]}, #{scheme}", describedby: readout_id },
        class: "h-9 w-12 shrink-0 cursor-pointer rounded-md border border-field bg-field p-0.5",
        data: {
          theme_live_preview_target: "field",
          variable: scheme == "dark" ? "--tenant-#{role[:role]}-dark" : "--tenant-#{role[:role]}",
          action: "input->theme-live-preview#apply"
        }
      )
      div(class: "min-w-0 text-xs") do
        span(class: "block font-medium text-muted") { scheme.capitalize }
        span(
          id: readout_id, class: "block max-w-48 text-muted",
          data: {
            theme_live_preview_target: "readout",
            role: role[:role], scheme: scheme, element: role[:element], text: role[:text], shade: role[:shade]
          }
        ) { span(class: "font-mono") { current } }
      end
    end
  end

  def font_field(form)
    div(class: "border-t border-default pt-4") do
      form.label :font_family, "Font", class: "block text-sm font-medium text-default"
      p(id: "theme-font-hint", class: "mt-0.5 mb-2 text-sm text-muted") do
        "A Google Fonts family, such as Inter or Roboto. Leave it blank for the default."
      end
      form.text_field :font_family,
        value: @tenant.font_family.presence || "",
        placeholder: "InterVariable",
        class: "#{Components::Kit::Field::INPUT} max-w-sm",
        aria: { describedby: "theme-font-hint" },
        data: {
          theme_live_preview_target: "field",
          variable: "--font-sans",
          action: "input->theme-live-preview#apply"
        }
    end
  end

  def scheme_note
    render Components::Kit::Alert.new(tone: :info) do
      "Each person sees the theme in light or dark, following their own setting: Auto, Light or Dark."
    end
  end

  def actions
    div(class: "flex justify-end gap-3") do
      render Components::Kit::Button.new(variant: :outline, data: { action: "theme-live-preview#revert" }) { "Cancel" }
      render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save" }
    end
  end
end
