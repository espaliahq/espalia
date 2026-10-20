# frozen_string_literal: true

# Tenant theme editor — the theme, its colour roles and typography.
#
# `show` renders the live-preview form; `update` persists via
# Operations::Tenants::UpdateTheme. The controller authorizes against
# TenantPolicy in addition to the Operation's own policy check
# (defense in depth per docs/guidelines/authorization.md).
#
class Tenant::ThemesController < ApplicationController
  # GET /tenant/theme
  def show
    authorize ActsAsTenant.current_tenant, :update_theme?, policy_class: TenantPolicy
    render Views::Tenant::Theme::EditView.new(
      tenant: ActsAsTenant.current_tenant,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  # PATCH /tenant/theme
  def update
    authorize ActsAsTenant.current_tenant, :update_theme?, policy_class: TenantPolicy

    Operations::Tenants::UpdateTheme.call(
      context: pundit_user,
      params: theme_params.to_h.symbolize_keys
    )
    redirect_to tenant_theme_path, notice: "Theme saved."
  rescue Operations::Base::ParameterError => e
    redirect_to tenant_theme_path, alert: "Theme could not be saved: #{e.message}", status: :see_other
  end

  private

  def theme_params
    params.expect(tenant: [
      :theme, :font_family,
      { custom_theme: Tenant::CUSTOM_ROLES.index_with { Tenant::SCHEMES } }
    ])
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
