# frozen_string_literal: true

# Management screens for tenant integrations.
#
# Surfaces the HRIS integration (provider/credential status, role mappings,
# titles nobody has mapped, and the resulting per-person assignments; tenant
# admins can trigger an on-demand re-sync, and mapping edits live in
# {Tenant::HrisTitleMappingsController}), the AI model page (settings live in
# {Tenant::AiModelsController}) and the feedback exchange page (settings live in
# {Tenant::FeedbackExchangesController}).
#
# Designed to be extended with additional integration types (Slack,
# notifications, SSO) by adding new branches in {#show}.
#
class Tenant::IntegrationsController < ApplicationController
  include AiModelPage
  include FeedbackExchangePage

  KNOWN_INTEGRATIONS = %w[hris ai-model feedback-exchange].freeze

  # GET /integrations
  def index
    authorize :integrations, :index?

    render Views::Integrations::IndexView.new(
      hris_config: current_tenant.hris_config,
      hris_credentials_present: current_tenant.hris_credentials.present?,
      slack_connected: current_tenant.slack_connected?,
      slack_team_name: current_tenant.slack_team_name,
      slack_available: Slack.configured?,
      ai_config: current_tenant.effective_ai_config,
      ai_state: current_tenant.effective_ai_config.state(current_tenant),
      feedback_exchange_config: current_tenant.feedback_exchange_config,
      feedback_exchange_secrets_present: current_tenant.feedback_exchange_secrets.complete?,
      feedback_exchange_summary: FeedbackExchangeImport.summary,
      user: current_user,
      current_tenant: current_tenant,
      tenants: tenants_for_user
    )
  end

  # GET /integrations/:id
  def show
    authorize :integrations, :show?

    case params.expect(:id)
    when "hris"
      render_hris
    when "ai-model"
      render_ai_model_page
    when "feedback-exchange"
      render_feedback_exchange_page
    else
      redirect_to tenant_integrations_path, alert: "Unknown integration."
    end
  end

  # POST /integrations/:id/sync
  def sync
    authorize :integrations, :sync?

    case params.expect(:id)
    when "hris"
      enqueue_hris_sync
    else
      redirect_to tenant_integrations_path, alert: "Unknown integration."
    end
  end

  private

  def render_hris
    resolution = Integrations::HrisTitleResolution.new(current_tenant)

    render Views::Integrations::HrisView.new(
      hris_config: current_tenant.hris_config,
      hris_credentials_present: current_tenant.hris_credentials.present?,
      person_rows: resolution.rows,
      role_mapping_rows: build_role_mapping_rows,
      unmapped_titles: unmapped_titles(resolution),
      mapping_options: mapping_options(resolution),
      can_edit_mappings: policy(:integrations).update_role_mappings?,
      user: current_user,
      current_tenant: current_tenant,
      tenants: tenants_for_user
    )
  end

  def enqueue_hris_sync
    if current_tenant.hris_config.configured?(current_tenant)
      HrisSyncJob.perform_later(current_tenant)
      redirect_to tenant_integration_path("hris"), notice: "HRIS sync queued. Refresh shortly to see updated results."
    else
      redirect_to tenant_integration_path("hris"),
                  alert: "HRIS integration is not fully configured — set provider, credentials, and enable sync."
    end
  end

  # Each role mapping resolves once for the table on the HRIS show page —
  # the badge needs to know whether the framework actually contains the
  # configured role code.
  #
  # @return [Array<Hash>] one entry per role mapping with status metadata
  def build_role_mapping_rows
    roles_by_code = FrameworkState::Role.all.index_by(&:code)

    current_tenant.hris_config.role_mappings.map do |mapping|
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
  def mapping_options(resolution)
    {
      roles: resolution.roles,
      level_ordinals_by_role_code: resolution.level_ordinals_by_role_code,
      hris_titles: resolution.titles.map(&:title),
      level_column_configured: current_tenant.hris_config.level_field_id.present?
    }
  end

  def current_tenant
    ActsAsTenant.current_tenant
  end
end
