# frozen_string_literal: true

# Renders the pay bands page, with its exchange rates panel, for the bands
# and the rates controllers. A refused form comes back with what was typed.
module PayBandsPage
  extend ActiveSupport::Concern

  private

  def authorize_pay_bands
    authorize ActsAsTenant.current_tenant, :manage_pay_bands?, policy_class: TenantPolicy
  end

  # @param drafts [Hash] what a refused form held, under :band, :rate or :reference
  # @param status [Symbol]
  def render_pay_bands_page(drafts: {}, status: :ok)
    render Views::Tenant::PayBands::IndexView.new(
      bands: Operations::Tenants::PayBands.call(context: pundit_user, params: {})[:pay_bands],
      rates: Operations::Tenants::ExchangeRates.call(context: pundit_user, params: {}),
      roles: FrameworkState::Role.includes(:levels).order(:name).to_a,
      countries: PayBand.known_countries,
      drafts:, **admin_shell
    ), status:
  end

  def admin_shell
    { user: current_user, current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a } }
  end
end
