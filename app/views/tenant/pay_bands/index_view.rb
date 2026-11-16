# frozen_string_literal: true

# The tenant's pay bands as one ordered list, and the form that adds one.
# Plans price a seat from the last band in the list that matches it ([#368](https://github.com/espaliahq/espalia/issues/368)),
# so the list's order is the precedence: an admin moves a band with its
# buttons, or drags it on a desktop.
class Views::Tenant::PayBands::IndexView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::PayBands::BandText
  include Views::Tenant::PayBands::FigureFields
  include Views::Tenant::PayBands::RatesPanel

  GONE = "No longer in the framework"
  SHADOWED = "Never used"
  # Holds the order the page shows once; each move button submits it with its
  # own band and direction in the URL, so the page doesn't grow with the square
  # of the list.
  MOVE_FORM = "pay-bands-move-form"

  # @param bands [Array<Hash>] as Operations::Tenants::PayBands lists them, in order
  # @param rates [Hash] as Operations::Tenants::ExchangeRates reads them: the reference currency and the rates
  # @param roles [Array<FrameworkState::Role>] with their levels and families, for the pickers
  # @param countries [Array<String>] the countries the Org Graph holds
  # @param drafts [Hash] what a refused form held, under :band, :rate or :reference, to show again
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(bands:, rates:, roles:, countries:, drafts: {}, user:, current_tenant:, tenants: [])
    @bands = bands
    @rates = rates
    @roles = roles
    @countries = countries
    @drafts = drafts
    @draft = drafts[:band] || {}
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
        subtitle: "What a seat pays, by role, level and country. Plans price positions from these. Only tenant admins see this page."
      )
      div(class: "grid gap-6 xl:grid-cols-[minmax(0,1fr)_24rem] xl:items-start") do
        div(class: "min-w-0 space-y-6") { bands_column }
        rates_panel
      end
    end
  end

  private

  def bands_column
    if @bands.empty?
      render Components::Kit::EmptyState.new(title: "No pay bands yet", size: :page) do
        plain "Add a band below. A band for every role and every level prices any seat at a framework level that no other band covers."
      end
    else
      order_card
    end
    add_card
  end

  def order_card
    render Components::Kit::Card.new(title: "The order", heading_level: :h2, id: "pay-bands-order") do |card|
      card.body do
        p(class: "text-sm text-muted") do
          plain "A seat takes its pay from the last band in this list that matches it, so put wide bands first " \
                "and narrow ones after. A new band lands below the bands wider than it."
        end
        div(data: { controller: "pay-band-order" }) do
          settings_form(reorder_tenant_pay_bands_path, method: :patch, id: "pay-bands-reorder-form", hidden: true,
                                                       data: { pay_band_order_target: "form" }) { }
          settings_form(reorder_tenant_pay_bands_path, method: :patch, id: MOVE_FORM, hidden: true) do
            @bands.each { input(type: "hidden", name: "from_pay_band_ids[]", value: it[:pay_band_id]) }
          end
          ol(class: "mt-4 divide-y divide-default", data: { pay_band_order_target: "list" }) do
            @bands.each_with_index { |band, index| band_row(band, index) }
          end
        end
      end
    end
  end

  def band_row(band, index)
    id = band[:pay_band_id]
    li(id: "pay-band-#{id}", class: "py-3 first:pt-0 last:pb-0 pointer-fine:cursor-grab data-[drag-source]:opacity-50",
       draggable: "true",
       data: { pay_band_id: id,
               action: "pointerdown->pay-band-order#press dragstart->pay-band-order#start dragover->pay-band-order#over " \
                       "drop->pay-band-order#drop dragend->pay-band-order#end" }) do
      div(class: "flex items-start gap-3") do
        span(class: "mt-0.5 w-6 shrink-0 text-right text-sm font-medium tabular-nums text-muted") { "#{band[:position]}." }
        div(class: "flex min-w-0 flex-1 flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4") do
          band_text(band)
          div(class: "flex shrink-0 items-center gap-2") do
            move_buttons(band, index)
            render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm,
                                               href: edit_tenant_pay_band_path(id), id: "pay-band-change-#{id}",
                                               aria_label: "Change the band for #{band_name(band)}") { "Change" }
            band_menu(band)
          end
        end
      end
    end
  end

  def band_text(band)
    div(class: "min-w-0 flex-1") do
      p(class: "flex flex-wrap items-center gap-2 text-sm font-medium text-default") do
        span do
          plain matcher_text(band)
          span(class: "text-muted font-normal") { " · #{band[:location] || 'Any location'}" }
        end
        render Components::Kit::Badge.new(GONE, tone: :neutral) unless band[:in_framework]
        render Components::Kit::Badge.new(SHADOWED, tone: :warning, id: "pay-band-shadowed-#{band[:pay_band_id]}") if band[:shadowed]
      end
      p(class: "text-sm text-default") { "#{range_text(band)}. #{midpoint_text(band)}." }
      p(class: "text-sm text-muted") { shadowed_text } if band[:shadowed]
      p(class: "text-xs text-muted") { changed_text(band) }
    end
  end

  def shadowed_text = "A band below it matches every seat this one does, so plans never use it. Move it down, or remove it."

  def move_buttons(band, index)
    div(class: "flex items-center gap-1") do
      move_button(band, index.positive?, "up")
      move_button(band, index < @bands.size - 1, "down")
    end
  end

  def move_button(band, allowed, direction)
    return span(class: "size-8 shrink-0", aria: { hidden: "true" }) unless allowed

    render Components::Kit::Button.new(
      variant: :ghost, tone: :neutral, size: :sm, icon: true, compact: true, type: :submit, form: MOVE_FORM,
      formaction: reorder_tenant_pay_bands_path(pay_band_id: band[:pay_band_id], direction:),
      id: "pay-band-#{direction}-#{band[:pay_band_id]}", aria_label: "Move the band for #{band_name(band)} #{direction}"
    ) { icon(:"chevron-#{direction}", class: "size-4") }
  end

  # Remove is destructive, so it sits in the row's kebab, which opens the dialog.
  def band_menu(band)
    name = band_name(band)
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
      "Plans price the seats it covers from the next band above it in the list that matches them, if there is one."
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
          p(class: "text-sm text-default") { "Publish a framework first: a band prices the seats of its roles." }
        else
          add_form
        end
      end
    end
  end

  def add_form
    settings_form(tenant_pay_bands_path, class: "space-y-4") do
      div(class: "grid gap-4 sm:grid-cols-3") do
        field("pay-band-reach", "Who") { reach_select }
        field("pay-band-level-ordinal", "Level", hint: "With a role, this picks that role's level.") do
          level_select
        end
        field("pay-band-location", "Country", hint: "Leave it blank for any country.") do
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

  def reach_select
    select(id: "pay-band-reach", name: "pay_band[reach]", class: Components::Kit::Field::SELECT) do
      option(value: "", selected: @draft[:reach].blank?) { PayBand::EVERY_ROLE }
      @roles.group_by(&:role_family).sort_by { |family, _| [ family ? 0 : 1, family&.name.to_s ] }.each do |family, roles|
        optgroup(label: family&.name.presence || "Roles in no family") do
          reach_option("family:#{family.role_family_id}", "Every role in #{family.name}") if family
          roles.each { reach_option("role:#{it.role_id}", it.name) }
        end
      end
    end
  end

  def reach_option(value, text) = option(value:, selected: @draft[:reach] == value) { text }

  def level_select
    top = @roles.flat_map(&:levels).map(&:ordinal).max.to_i
    select(id: "pay-band-level-ordinal", name: "pay_band[level_ordinal]", class: Components::Kit::Field::SELECT,
           aria: { describedby: "pay-band-level-ordinal-hint" }) do
      option(value: "", selected: @draft[:level_ordinal].blank?) { PayBand::EVERY_LEVEL }
      (1..top).each { |ordinal| option(value: ordinal, selected: @draft[:level_ordinal].to_s == ordinal.to_s) { "Level #{ordinal}" } }
    end
  end
end
