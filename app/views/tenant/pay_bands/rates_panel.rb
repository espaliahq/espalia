# frozen_string_literal: true

# The exchange rates panel beside the bands: the reference currency reports
# total in, and the rates that convert each band's currency to it. Nothing is
# converted here; a report converts once, on the date it reports.
module Views::Tenant::PayBands::RatesPanel
  private

  def rates_panel
    render Components::Kit::Card.new(title: "Exchange rates", heading_level: :h2, id: "exchange-rates") do |card|
      card.body do
        div(class: "space-y-6") do
          reference_form
          rate_list
          add_rate_form
        end
      end
    end
  end

  def reference = @rates[:reference_currency]

  def reference_form
    draft = @drafts[:reference] || {}
    settings_form(tenant_reference_currency_path, method: :patch, class: "space-y-2") do
      field("reference-currency", "Reference currency",
            hint: reference ? "Reports total in this currency. #{changed_text(reference)}." : "Not set yet. Reports need one to total pay in more than one currency.") do
        div(class: "flex gap-2") do
          input(id: "reference-currency", name: "reference_currency[currency]", type: "text", required: true, maxlength: 3,
                value: draft[:currency] || reference&.dig(:currency), autocomplete: "off",
                class: "#{Components::Kit::Field::INPUT} uppercase", aria: { describedby: "reference-currency-hint" })
          render Components::Kit::Button.new(type: :submit, variant: :outline, tone: :neutral, id: "reference-currency-save") { "Set" }
        end
      end
    end
  end

  def rate_list
    div do
      h3(class: "text-sm font-medium text-default") { "Rates" }
      if @rates[:exchange_rates].empty?
        p(class: "mt-1 text-sm text-muted") { "No rates yet. A report that meets a currency with no rate stops and names the pair." }
      else
        ul(class: "mt-1 divide-y divide-default") { @rates[:exchange_rates].each { rate_row(it) } }
      end
    end
  end

  def rate_row(rate)
    li(id: "exchange-rate-#{rate[:exchange_rate_id]}", class: "py-3 last:pb-0") do
      div(class: "flex items-start justify-between gap-2") do
        div(class: "min-w-0") do
          p(class: "text-sm text-default") do
            plain "1 #{rate[:from_currency]} = #{rate[:rate]} #{rate[:to_currency]}"
            span(class: "text-muted") { " · from #{rate_day(rate)}" }
          end
          p(class: "text-xs text-muted") { changed_text(rate) }
        end
        div(class: "flex shrink-0 items-center gap-1") do
          render Components::Kit::Button.new(variant: :outline, tone: :neutral, size: :sm,
                                             href: edit_tenant_exchange_rate_path(rate[:exchange_rate_id]),
                                             id: "exchange-rate-change-#{rate[:exchange_rate_id]}",
                                             aria_label: "Change the rate #{rate_name(rate)}") { "Change" }
          rate_menu(rate)
        end
      end
    end
  end

  def rate_menu(rate)
    id = rate[:exchange_rate_id]
    render Components::Kit::Modal.new(id: "exchange-rate-remove-#{id}", title: "Remove the rate #{rate_name(rate)}?", size: :sm) do |modal|
      render Components::Kit::Dropdown.new(align: :right, strategy: :fixed) do |menu|
        menu.trigger(label: "Actions for the rate #{rate_name(rate)}",
                     button: { variant: :ghost, size: :sm, icon: true, compact: true, id: "exchange-rate-menu-#{id}" }) do
          icon(:kebab, class: "size-4")
        end
        menu.menu(width: "w-44") do
          menu.item(tone: :danger, data: { action: "modal#open" }, id: "exchange-rate-remove-item-#{id}") { "Remove the rate" }
        end
      end
      modal.body do
        p(class: "text-sm text-default") do
          "Reports dated from #{rate_day(rate)} use the latest remaining rate between the two currencies, " \
            "either way round, and stop if none applies."
        end
        settings_form(tenant_exchange_rate_path(id), method: :delete, class: "mt-4 flex justify-end gap-2") do
          render Components::Kit::Button.new(variant: :outline, tone: :neutral, data: { action: "modal#close" }) { "Cancel" }
          render Components::Kit::Button.new(tone: :danger, type: :submit, id: "exchange-rate-remove-confirm-#{id}") { "Remove the rate" }
        end
      end
    end
  end

  def add_rate_form
    draft = @drafts[:rate] || {}
    settings_form(tenant_exchange_rates_path, class: "space-y-4 border-t border-default pt-4") do
      h3(class: "text-sm font-medium text-default") { "Add a rate" }
      div(class: "grid grid-cols-2 gap-4") do
        currency_input("exchange-rate-from", "From", "from_currency", draft[:from_currency])
        currency_input("exchange-rate-to", "To", "to_currency", draft[:to_currency] || reference&.dig(:currency))
      end
      field("exchange-rate-rate", "Rate", hint: "What one From is worth in To, with a point for decimals, such as 0.92.") do
        input(id: "exchange-rate-rate", name: "exchange_rate[rate]", type: "text", inputmode: "decimal", required: true,
              value: draft[:rate], autocomplete: "off", class: Components::Kit::Field::INPUT,
              aria: { describedby: "exchange-rate-rate-hint" })
      end
      field("exchange-rate-applies-from", "Applies from", hint: "A plan dated on or after this day uses this rate.") do
        input(id: "exchange-rate-applies-from", name: "exchange_rate[applies_from]", type: "date", required: true,
              value: draft[:applies_from], class: Components::Kit::Field::INPUT,
              aria: { describedby: "exchange-rate-applies-from-hint" })
      end
      div(class: "flex justify-end") do
        render Components::Kit::Button.new(type: :submit, id: "exchange-rate-add") { "Add the rate" }
      end
    end
  end

  def currency_input(id, label_text, name, value)
    field(id, label_text) do
      input(id:, name: "exchange_rate[#{name}]", type: "text", required: true, maxlength: 3, value:, autocomplete: "off",
            class: "#{Components::Kit::Field::INPUT} uppercase")
    end
  end

  def rate_name(rate) = "from #{rate[:from_currency]} to #{rate[:to_currency]} applying from #{rate_day(rate)}"

  def rate_day(rate) = day_text(rate[:applies_from])
end
