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
  include HrisPage
  include AiModelPage
  include FeedbackExchangePage

  KNOWN_INTEGRATIONS = %w[hris ai-model feedback-exchange].freeze

  # GET /integrations
  def index
    authorize :integrations, :index?

    render Views::Integrations::IndexView.new(
      hris_config: current_tenant.hris_config,
      hris_credentials_present: current_tenant.hris_secrets.complete?,
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
      render_hris_page
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

  def enqueue_hris_sync
    if current_tenant.hris_config.configured?(current_tenant)
      HrisSyncJob.perform_later(current_tenant)
      redirect_to tenant_integration_path("hris"), notice: "HRIS sync queued. Refresh shortly to see updated results."
    else
      redirect_to tenant_integration_path("hris"),
                  alert: "HRIS integration is not fully configured — set provider, credentials, and enable sync."
    end
  end

  def current_tenant
    ActsAsTenant.current_tenant
  end
end
