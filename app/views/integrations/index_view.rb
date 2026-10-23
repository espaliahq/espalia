# frozen_string_literal: true

# Lists every integration available to the current tenant.
#
# Surfaces HRIS, Slack, the AI model and the feedback exchange; further integration types
# (notifications, SSO) will appear here as they're built.
#
class Views::Integrations::IndexView < Views::Base
  # @param hris_config [HrisConfig]
  # @param hris_credentials_present [Boolean]
  # @param ai_config [AiModelConfig]
  # @param ai_state [Symbol] one of {Views::Integrations::AiModelView::STATE_BADGES}
  # @param feedback_exchange_config [FeedbackExchangeConfig]
  # @param feedback_exchange_secrets_present [Boolean] both signing secrets stored
  # @param feedback_exchange_summary [Hash, nil] {FeedbackExchangeImport.summary}
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(hris_config:, hris_credentials_present:, slack_connected: false, slack_team_name: nil, slack_available: false,
                 ai_config: AiModelConfig.new, ai_state: :not_configured,
                 feedback_exchange_config: FeedbackExchangeConfig.new, feedback_exchange_secrets_present: false,
                 feedback_exchange_summary: nil,
                 user: nil, current_tenant: nil, tenants: [])
    @hris_config = hris_config
    @hris_credentials_present = hris_credentials_present
    @slack_connected = slack_connected
    @slack_team_name = slack_team_name
    @slack_available = slack_available
    @ai_config = ai_config
    @ai_state = ai_state
    @feedback_exchange_config = feedback_exchange_config
    @feedback_exchange_secrets_present = feedback_exchange_secrets_present
    @feedback_exchange_summary = feedback_exchange_summary
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :integrations,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-5xl mx-auto") do
        page_header
        integration_grid
      end
    end
  end

  private

  def page_header
    render Components::Kit::SectionHeading.new(
      "Integrations",
      subtitle: "Manage external systems connected to this workspace"
    )
  end

  def integration_grid
    div(class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6") do
      hris_card
      slack_card
      ai_model_card
      feedback_exchange_card
    end
  end

  def ai_model_card
    a(href: tenant_integration_path("ai-model"), class: "block group") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex items-start justify-between") do
            div do
              h3(class: "text-lg font-semibold text-gray-900 dark:text-white " \
                        "group-hover:text-primary-ink transition-colors") { "AI model" }
              p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { ai_model_subtitle }
            end
            label, variant = Views::Integrations::AiModelView::STATE_BADGES.fetch(@ai_state)
            render Components::Kit::Badge.new(label, variant: variant)
          end
        end
      end
    end
  end

  def ai_model_subtitle
    return "Choose the model that suggests where feedback belongs" if @ai_state == :not_configured

    "#{@ai_config.model.presence || AiModelConfig::DEFAULT_ANTHROPIC_MODEL} · " \
      "#{@ai_config.base_host || Views::Integrations::AiModelView::PROVIDER_LABELS.fetch(@ai_config.provider)}"
  end

  def slack_card
    render Components::Kit::Card.new do |card|
      card.body do
        div(class: "flex items-start justify-between") do
          div do
            h3(class: "text-lg font-semibold text-gray-900 dark:text-white") { "Slack" }
            p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { slack_subtitle }
          end
          render Components::Kit::Badge.new(
            @slack_connected ? "Connected" : "Not connected",
            variant: @slack_connected ? :success : :default
          )
        end
        div(class: "mt-4") { slack_action }
      end
    end
  end

  def slack_subtitle
    return "Send assessment notifications to Slack" unless @slack_connected

    @slack_team_name.present? ? "Connected to #{@slack_team_name}" : "Workspace connected"
  end

  def slack_action
    if @slack_connected
      # Always offer disconnect when connected, even if the app's OAuth config
      # later changes — otherwise an admin couldn't sever a stale connection.
      a(
        href: tenant_slack_connection_path,
        data: { turbo_method: :delete, turbo_confirm: "Disconnect Slack from this workspace?" },
        class: "inline-flex items-center min-h-11 text-sm font-medium text-red-700 dark:text-red-400 hover:underline"
      ) { "Disconnect" }
    elsif @slack_available
      a(
        href: tenant_slack_install_path,
        data: { turbo_frame: "_top" },
        class: "inline-flex items-center min-h-11 px-4 rounded-md bg-primary text-white text-sm font-medium hover:opacity-90"
      ) { "Connect Slack" }
    else
      span(class: "text-xs text-gray-600 dark:text-gray-300") { "Slack is not configured for this deployment." }
    end
  end

  def feedback_exchange_card
    a(href: tenant_integration_path("feedback-exchange"), class: "block group") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex items-start justify-between") do
            div do
              h3(class: "text-lg font-semibold text-gray-900 dark:text-white " \
                        "group-hover:text-primary-ink transition-colors") { "Feedback exchange" }
              p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { feedback_exchange_subtitle }
            end
            render Components::Kit::Badge.new(feedback_exchange_status.first, variant: feedback_exchange_status.last)
          end
          div(class: "mt-4 flex flex-wrap gap-x-4 gap-y-1 text-xs text-gray-600 dark:text-gray-300") do
            span { "Last synced: #{@feedback_exchange_config.last_synced_at&.to_fs(:long) || 'Never'}" }
            span(id: "feedback-exchange-card-counts") { feedback_exchange_counts } if feedback_exchange_counts
          end
        end
      end
    end
  end

  # @return [String, nil] "Imported 12 · Updated 2 · Skipped 3", plus withdrawals when
  #   there are any, once anything has crossed
  def feedback_exchange_counts
    summary = @feedback_exchange_summary
    return if summary.nil? || summary.values_at(:imported, :updated, :skipped, :withdrawn).sum.zero?

    parts = [ "Imported #{summary[:imported]}", "Updated #{summary[:updated]}", "Skipped #{summary[:skipped]}" ]
    parts << "Withdrawn #{summary[:withdrawn]}" if summary[:withdrawn].positive?
    parts.join(" · ")
  end

  def feedback_exchange_subtitle
    peer = @feedback_exchange_config.peer_name.presence
    peer ? "Feedback shared with #{peer}" : "Share named feedback with another feedback system"
  end

  # @return [Array(String, Symbol)] label and Kit::Badge variant
  def feedback_exchange_status
    state = @feedback_exchange_config.state(secrets_complete: @feedback_exchange_secrets_present)
    Views::Integrations::FeedbackExchangeView::STATE_BADGES.fetch(state)
  end

  def hris_card
    a(href: tenant_integration_path("hris"), class: "block group") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex items-start justify-between") do
            div do
              h3(class: "text-lg font-semibold text-gray-900 dark:text-white " \
                        "group-hover:text-primary-ink transition-colors") { "HRIS" }
              p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
                plain provider_label
              end
            end
            render Components::Kit::Badge.new(status_label, variant: status_variant)
          end

          div(class: "mt-4 text-xs text-gray-600 dark:text-gray-300") do
            plain "Last synced: #{last_synced_label}"
          end
        end
      end
    end
  end

  def provider_label
    return "Not configured" if @hris_config.provider.blank?

    @hris_config.provider.humanize
  end

  def status_label
    return "Not configured" if @hris_config.provider.blank?
    return "Missing credentials" unless @hris_credentials_present
    return "Disabled" unless @hris_config.sync_enabled?

    "Active"
  end

  def status_variant
    return :default if @hris_config.provider.blank?
    return :warning unless @hris_credentials_present
    return :default unless @hris_config.sync_enabled?

    :success
  end

  def last_synced_label
    @hris_config.last_synced_at&.to_fs(:long) || "Never"
  end
end
