# frozen_string_literal: true

# Corrects one exchange rate's value. Its pair and date are its key, so
# changing either is removing the rate and adding another.
class Views::Tenant::ExchangeRates::EditView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::PayBands::BandText
  include Views::Tenant::PayBands::FigureFields

  # @param rate [Hash] as Operations::Tenants::ExchangeRates lists it, with any typed rate merged in
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(rate:, user:, current_tenant:, tenants: [])
    @rate = rate
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :pay_bands, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new("Change an exchange rate", tag: :h1, subtitle: changed_text(@rate))
      render Components::Kit::Card.new(title: title, heading_level: :h2, id: "exchange-rate-edit") do |card|
        card.body do
          settings_form(tenant_exchange_rate_path(@rate[:exchange_rate_id]), method: :patch, class: "space-y-4") do
            p(class: "text-sm text-muted") { "To change the currencies or the date, remove this rate and add another." }
            field("exchange-rate-rate", "1 #{@rate[:from_currency]} is worth, in #{@rate[:to_currency]}",
                  hint: "A number above zero with a point for decimals, such as 0.92.") do
              input(id: "exchange-rate-rate", name: "exchange_rate[rate]", type: "text", inputmode: "decimal", required: true,
                    value: @rate[:rate], autocomplete: "off", class: Components::Kit::Field::INPUT,
                    aria: { describedby: "exchange-rate-rate-hint" })
            end
            div(class: "flex justify-end gap-2") do
              render Components::Kit::Button.new(variant: :outline, tone: :neutral, href: tenant_pay_bands_path) { "Cancel" }
              render Components::Kit::Button.new(type: :submit, id: "exchange-rate-save") { "Save the rate" }
            end
          end
        end
      end
    end
  end

  private

  def title = "#{@rate[:from_currency]} to #{@rate[:to_currency]}, from #{day_text(@rate[:applies_from])}"
end
