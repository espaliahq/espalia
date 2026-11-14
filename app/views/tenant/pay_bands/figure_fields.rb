# frozen_string_literal: true

# The labelled fields a band's add and change forms share: currency, period
# and the three figures.
module Views::Tenant::PayBands::FigureFields
  PERIOD_LABELS = { "year" => "A year", "month" => "A month", "hour" => "An hour" }.freeze

  private

  # @param values [Hash] what the form shows: a band's payload, or what was typed
  def figure_fields(values)
    div(class: "grid gap-4 sm:grid-cols-2") do
      field("pay-band-currency", "Currency", hint: "A three-letter code, such as AUD.") do
        input(id: "pay-band-currency", name: "pay_band[currency]", type: "text", required: true, maxlength: 3,
              value: values[:currency], autocomplete: "off", class: "#{Components::Kit::Field::INPUT} uppercase",
              aria: { describedby: "pay-band-currency-hint" })
      end
      field("pay-band-period", "Paid per") do
        select(id: "pay-band-period", name: "pay_band[period]", required: true, class: Components::Kit::Field::SELECT) do
          PERIOD_LABELS.each { |value, label| option(value:, selected: (values[:period] || "year") == value) { label } }
        end
      end
    end
    div(class: "grid gap-4 sm:grid-cols-3") do
      PayBand::FIGURES.each do |name|
        field("pay-band-#{name}", name.to_s.capitalize) do
          input(id: "pay-band-#{name}", name: "pay_band[#{name}]", type: "text", inputmode: "decimal", required: true,
                value: values[name], autocomplete: "off", class: Components::Kit::Field::INPUT)
        end
      end
    end
  end

  def field(id, label_text, hint: nil, &)
    div do
      label(for: id, class: "block text-sm font-medium text-default mb-1") { label_text }
      yield
      p(id: "#{id}-hint", class: "mt-1 text-xs text-muted") { hint } if hint
    end
  end
end
