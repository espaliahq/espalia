# frozen_string_literal: true

# Set the active tenant's theme: Default, the Bento preset, or Custom with the
# tenant's own colour-role values and font (ADR-23, #550).
#
# `custom_theme` merges into what is stored, role by role and scheme by
# scheme, so a call that sets the brand leaves the navbar alone; a blank value
# clears that one, and Default's applies again. The payload is checked against
# the model before saving, so a bad role or colour is invalid input (-32602
# over MCP), not an internal error.
#
# Approval is :in_app because this changes how the tenant's UI looks
# for every member. From the web the form already IS the in-app
# surface; from MCP the in-app gate prevents an agent loop from
# silently repainting a customer's UI.
#
class Operations::Tenants::UpdateTheme < Operations::Base
  HEX_PATTERN = "^#[0-9a-fA-F]{6}$"

  description "Update the active tenant's theme: default, bento, or custom with its own " \
              "colour-role values (light and dark hex) and Google font. custom_theme merges " \
              "per role; a blank value restores the default for that role. product_name is " \
              "what this tenant calls the platform; blank restores the instance default."
  category :write
  approval :in_app

  parameter :theme, String, allowed: Tenant::THEMES
  parameter :custom_theme, Hash, schema: {
    type: "object",
    properties: Tenant::CUSTOM_ROLES.index_with do
      {
        type: "object",
        properties: Tenant::SCHEMES.index_with { { type: "string", pattern: "#{HEX_PATTERN}|^$" } },
        additionalProperties: false
      }
    end,
    additionalProperties: false
  }
  parameter :font_family, String
  parameter :product_name, String

  def policy_check
    authorize ActsAsTenant.current_tenant, :update_theme?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id, the attributes written, and the theme as it now stands
  def perform
    tenant = ActsAsTenant.current_tenant
    updates = params.compact
    if updates.key?(:custom_theme)
      updates[:custom_theme] = tenant.custom_theme.deep_merge(updates[:custom_theme].deep_stringify_keys)
    end

    tenant.assign_attributes(updates)
    unless tenant.valid?
      message = tenant.errors.full_messages.to_sentence
      # The request's layout still renders from this tenant, so a rejected theme must not reach it
      tenant.restore_attributes(updates.keys)
      tenant.errors.clear
      raise ParameterError, message
    end

    tenant.save! if updates.any?
    {
      tenant_id: tenant.id,
      updated: updates.keys,
      theme: { theme: tenant.theme, custom_theme: tenant.custom_theme, font_family: tenant.font_family }
    }
  end
end
