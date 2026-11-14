# frozen_string_literal: true

# The tenant's pay bands, a card per role, and the form that adds one.
# Team Planning prices positions from these, so a band whose level has left
# the framework is listed apart until someone removes it.
class Views::Tenant::PayBands::IndexView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::PayBands::BandText
  include Views::Tenant::PayBands::FigureFields

  GONE = "No longer in the framework"

  # @param bands [Array<Hash>] as Operations::Tenants::PayBands lists them
  # @param roles [Array<FrameworkState::Role>] with their levels, for the level picker
  # @param countries [Array<String>] the countries the Org Graph holds
  # @param draft [Hash] what a refused add form held, to show again
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(bands:, roles:, countries:, draft: {}, user:, current_tenant:, tenants: [])
    @bands = bands
    @roles = roles
    @countries = countries
    @draft = draft
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :pay_bands, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Pay bands", tag: :h1,
        subtitle: "What each level pays, by country. Plans price positions from these. Only tenant admins see this page."
      )
      div(class: "space-y-6") do
        if @bands.empty?
          render Components::Kit::EmptyState.new(title: "No pay bands yet", size: :page) do
            plain "Add a band for a level below. A band with no location prices that level anywhere."
          end
        end
        groups.each { |title, bands| role_card(title, bands) }
        add_card
      end
    end
  end

  private

  def groups
    @bands.group_by { it[:in_framework] ? role_name(it) : GONE }
  end

  def role_name(band) = band[:level].split(", ").first

  def level_name(band) = band[:level].split(", ", 2).last

  def role_card(title, bands)
    render Components::Kit::Card.new(title:, heading_level: :h2, id: "pay-bands-#{title.parameterize}") do |card|
      card.body do
        p(class: "text-sm text-muted") { "Plans don't price positions at these levels. Remove them once no one needs them." } if title == GONE
        ul(class: "divide-y divide-default") { bands.each { band_row(it) } }
      end
    end
  end

  def band_row(band)
    li(id: "pay-band-#{band[:pay_band_id]}", class: "py-3 first:pt-0 last:pb-0") do
      div(class: "flex flex-wrap items-start justify-between gap-x-4 gap-y-2") do
        div(class: "min-w-0") do
          p(class: "text-sm font-medium text-default") do
            plain level_name(band)
            span(class: "text-muted font-normal") { " · #{band[:location] || 'Any location'}" }
          end
          p(class: "text-sm text-default") { "#{range_text(band)}. #{midpoint_text(band)}." }
          p(class: "text-xs text-muted") { changed_text(band) }
        end
        div(class: "flex shrink-0 items-center gap-2") do
          render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm,
                                             href: edit_tenant_pay_band_path(band[:pay_band_id]),
                                             id: "pay-band-change-#{band[:pay_band_id]}",
                                             aria_label: "Change the band for #{band[:level]}, #{band[:location] || 'any location'}") { "Change" }
          band_menu(band)
        end
      end
    end
  end

  # Remove is destructive, so it sits in the row's kebab, which opens the dialog.
  def band_menu(band)
    name = "#{band[:level]}, #{band[:location] || 'any location'}"
    render Components::Kit::Modal.new(id: "pay-band-remove-#{band[:pay_band_id]}", title: "Remove the band for #{name}?",
                                      size: :sm) do |modal|
      render Components::Kit::Dropdown.new(align: :right, strategy: :fixed) do |menu|
        menu.trigger(label: "Actions for the band for #{name}",
                     button: { variant: :ghost, size: :sm, icon: true, compact: true,
                               id: "pay-band-menu-#{band[:pay_band_id]}" }) do
          icon(:kebab, class: "size-4")
        end
        menu.menu(width: "w-44") do
          menu.item(tone: :danger, data: { action: "modal#open" }, id: "pay-band-remove-item-#{band[:pay_band_id]}") do
            "Remove the band"
          end
        end
      end
      modal.body { remove_form(band) }
    end
  end

  def remove_form(band)
    p(class: "text-sm text-default") do
      band[:location] ? "Plans price this level in #{band[:location]} from its any-location band, if it has one." : "Plans price this level only where a country band covers it."
    end
    settings_form(tenant_pay_band_path(band[:pay_band_id]), method: :delete, class: "mt-4 flex justify-end gap-2") do
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, data: { action: "modal#close" }) { "Cancel" }
      render Components::Kit::Button.new(tone: :danger, type: :submit, id: "pay-band-remove-confirm-#{band[:pay_band_id]}") do
        "Remove the band"
      end
    end
  end

  def add_card
    render Components::Kit::Card.new(title: "Add a band", heading_level: :h2, id: "pay-bands-add") do |card|
      card.body do
        if @roles.empty?
          p(class: "text-sm text-default") { "Publish a framework first: a band belongs to one of its levels." }
        else
          add_form
        end
      end
    end
  end

  def add_form
    settings_form(tenant_pay_bands_path, class: "space-y-4") do
      div(class: "grid gap-4 sm:grid-cols-2") do
        field("pay-band-level", "Level") { level_select }
        field("pay-band-location", "Country", hint: "Leave it blank to price this level anywhere no country band covers.") do
          input(id: "pay-band-location", name: "pay_band[location]", type: "text", list: "pay-band-countries",
                value: @draft[:location], autocomplete: "off", class: Components::Kit::Field::INPUT,
                aria: { describedby: "pay-band-location-hint" })
          datalist(id: "pay-band-countries") { @countries.each { option(value: it) } }
        end
      end
      figure_fields(@draft)
      div(class: "flex justify-end") do
        render Components::Kit::Button.new(type: :submit, id: "pay-band-add") { "Add the band" }
      end
    end
  end

  def level_select
    select(id: "pay-band-level", name: "pay_band[level_id]", required: true, class: Components::Kit::Field::SELECT) do
      option(value: "") { "Choose a level" }
      @roles.each do |role|
        optgroup(label: role.name) do
          role.levels.sort_by(&:ordinal).each do |level|
            option(value: level.level_id, selected: @draft[:level_id] == level.level_id) { "#{level.code} #{level.title}" }
          end
        end
      end
    end
  end
end
