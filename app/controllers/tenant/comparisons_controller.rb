# frozen_string_literal: true

# Whether people can compare their assessment with their level, the smallest
# group that shows, and how often the group scores are taken. Tenant admins only.
class Tenant::ComparisonsController < ApplicationController
  # GET /tenant/comparisons
  def show
    authorize ActsAsTenant.current_tenant, :update_comparisons?, policy_class: TenantPolicy
    render_page
  end

  # PATCH /tenant/comparisons
  def update
    authorize ActsAsTenant.current_tenant, :update_comparisons?, policy_class: TenantPolicy
    result = Operations::Tenants::UpdateComparisons.call(context: pundit_user, params: comparison_params)
    redirect_to tenant_comparisons_path, notice: "Comparisons are #{result[:enabled] ? 'on' : 'off'}. Saved.",
                                         status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The comparison settings could not be saved: #{e.message.delete_suffix('.')}."
    render_page(status: :unprocessable_content)
  end

  private

  def comparison_params
    raw = params.expect(comparisons: [ :enabled, :min_group_size, :snapshot_every_months ])
    { enabled: (ActiveModel::Type::Boolean.new.cast(raw[:enabled]) if raw.key?(:enabled)),
      min_group_size: raw[:min_group_size].presence&.to_i,
      snapshot_every_months: raw[:snapshot_every_months].presence&.to_i }.compact
  end

  def render_page(status: :ok)
    tenant = ActsAsTenant.current_tenant
    render Views::Tenant::Comparisons::ShowView.new(
      settings: Operations::Tenants::Comparisons.payload(tenant), user: current_user, current_tenant: tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a }
    ), status:
  end
end
