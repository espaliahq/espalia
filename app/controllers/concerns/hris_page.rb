# frozen_string_literal: true

# Renders the HRIS integration page, for the integrations show action and for a
# connection save that failed validation and must redisplay the form.
module HrisPage
  extend ActiveSupport::Concern

  private

  # @return [Array<Tenant>] the tenants the signed-in user can switch to
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end

  # Status always shows what is saved. After a rejected save the form keeps what
  # the admin typed, but the status rows must not claim values that were never
  # stored — and a secret is never echoed either way.
  #
  # @param errors [Array<String>] validation messages to show above the form
  # @param status [Symbol]
  def render_hris_page(errors: [], status: :ok)
    tenant = ActsAsTenant.current_tenant
    saved = errors.empty? ? tenant : Tenant.find(tenant.id)
    resolution = Integrations::HrisTitleResolution.new(saved)

    render Views::Integrations::HrisView.new(
      hris_config: saved.hris_config,
      form_config: tenant.hris_config, # after a rejected save this holds what was typed
      hris_secrets_stored: saved.hris_secrets.stored,
      person_rows: resolution.rows,
      role_mapping_rows: build_role_mapping_rows(saved),
      unmapped_titles: unmapped_titles(resolution),
      mapping_options: mapping_options(resolution, saved),
      can_edit_mappings: policy(:integrations).update_role_mappings?,
      can_edit_connection: policy(:integrations).update_hris_connection?,
      errors: errors,
      user: current_user,
      current_tenant: saved,
      tenants: tenants_for_user
    ), status: status
  end

  # Each role mapping resolves once for the table on the HRIS show page —
  # the badge needs to know whether the framework actually contains the
  # configured role code.
  #
  # @return [Array<Hash>] one entry per role mapping with status metadata
  def build_role_mapping_rows(tenant)
    roles_by_code = FrameworkState::Role.all.index_by(&:code)

    tenant.hris_config.role_mappings.map do |mapping|
      role = roles_by_code[mapping.framework_role_code]
      {
        mapping: mapping,
        role: role,
        status_label: role.nil? ? "Missing role" : "OK",
        status_variant: role.nil? ? :warning : :success
      }
    end
  end

  # Titles nobody has mapped, those whose holders are still on an assignment
  # an earlier title gave them first — they are the ones visibly wrong.
  #
  # @return [Array<Integrations::HrisTitleResolution::Title>]
  def unmapped_titles(resolution)
    stale, rest = resolution.titles.select(&:unmapped?).partition { |entry| entry.attention_rows.any? }
    stale + rest
  end

  # What the mapping modal offers: the framework's roles, each role's levels,
  # and every title HRIS people currently hold (for the title field's
  # suggestions).
  #
  # @return [Hash]
  def mapping_options(resolution, tenant)
    {
      roles: resolution.roles,
      level_ordinals_by_role_code: resolution.level_ordinals_by_role_code,
      hris_titles: resolution.titles.map(&:title),
      level_column_configured: tenant.hris_config.level_field_id.present?
    }
  end
end
