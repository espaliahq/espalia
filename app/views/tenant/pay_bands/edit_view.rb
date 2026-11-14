# frozen_string_literal: true

# Changes one band's currency, period and figures. Its level and location
# are its key, so changing either is removing the band and adding another.
class Views::Tenant::PayBands::EditView < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::PayBands::BandText
  include Views::Tenant::PayBands::FigureFields

  # @param band [Hash] as Operations::Tenants::PayBands lists it, with any typed values merged in
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(band:, user:, current_tenant:, tenants: [])
    @band = band
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :pay_bands, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new("Change a pay band", tag: :h1, subtitle: changed_text(@band))
      render Components::Kit::Card.new(title: band_name, heading_level: :h2, id: "pay-band-edit") do |card|
        card.body do
          settings_form(tenant_pay_band_path(@band[:pay_band_id]), method: :patch, class: "space-y-4") do
            p(class: "text-sm text-muted") do
              "To change the level or country, remove this band and add another."
            end
            figure_fields(@band)
            div(class: "flex justify-end gap-2") do
              render Components::Kit::Button.new(variant: :outline, tone: :neutral, href: tenant_pay_bands_path) { "Cancel" }
              render Components::Kit::Button.new(type: :submit, id: "pay-band-save") { "Save the band" }
            end
          end
        end
      end
    end
  end

  private

  def band_name = "#{@band[:level]}, #{@band[:location] || 'any location'}"
end
