# frozen_string_literal: true

# Persist tenant theme settings (brand colors + font) on the active
# Tenant. Updates the `settings` store_accessor fields on {Tenant};
# Tenant model validations enforce hex-color format and font_family
# shape, so invalid input surfaces as ActiveRecord::RecordInvalid.
#
# Approval is :in_app because this changes how the tenant's UI looks
# for every member. From the web the form already IS the in-app
# surface; from MCP the in-app gate prevents an agent loop from
# silently repainting a customer's UI.
#
class Operations::Tenants::UpdateTheme < Operations::Base
  description "Update the active tenant's theme (brand colors and font)."
  category :write
  approval :in_app

  parameter :primary_color,        String
  parameter :primary_color_dark,   String
  parameter :secondary_color,      String
  parameter :secondary_color_dark, String
  parameter :nav_bg_color,         String
  parameter :nav_bg_color_dark,    String
  parameter :nav_fg_color,         String
  parameter :nav_fg_color_dark,    String
  parameter :font_family,          String

  def policy_check
    authorize ActsAsTenant.current_tenant, :update_theme?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id + the list of attribute keys that were updated
  def perform
    tenant = ActsAsTenant.current_tenant
    updates = params.compact
    tenant.update!(updates) if updates.any?
    { tenant_id: tenant.id, updated: updates.keys }
  end
end
