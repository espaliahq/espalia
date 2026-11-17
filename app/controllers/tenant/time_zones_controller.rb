# frozen_string_literal: true

# The tenant's time zone, which decides its "today" ([#469](https://github.com/espaliahq/espalia/issues/469)). Tenant admins only.
class Tenant::TimeZonesController < ApplicationController
  # GET /tenant/time_zone
  def show
    authorize ActsAsTenant.current_tenant, :update_time_zone?, policy_class: TenantPolicy
    render_page
  end

  # PATCH /tenant/time_zone
  def update
    authorize ActsAsTenant.current_tenant, :update_time_zone?, policy_class: TenantPolicy
    result = Operations::Tenants::SetTimeZone.call(context: pundit_user, params: time_zone_params)
    today = I18n.l(Date.iso8601(result[:today]), format: Views::Tenant::TimeZone::EditView::DATE_FORMAT)
    redirect_to tenant_time_zone_path, notice: "Today is now #{today} in #{result[:time_zone]}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The time zone could not be set: #{e.message.delete_suffix('.')}."
    render_page(status: :unprocessable_content, chosen: time_zone_params[:time_zone])
  end

  private

  def time_zone_params = params.expect(tenant: [ :time_zone ]).to_h.symbolize_keys

  def render_page(status: :ok, chosen: nil)
    tenant = ActsAsTenant.current_tenant
    render Views::Tenant::TimeZone::EditView.new(
      tenant:, chosen:, user: current_user, current_tenant: tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a }
    ), status:
  end
end
