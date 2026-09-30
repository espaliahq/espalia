# frozen_string_literal: true

# OAuth consent screen for MCP client authorisation.
#
# Surfaces the client application name, the scopes it's asking for, and a
# tenant picker (the issued access token is bound to exactly one tenant —
# the user re-authorises to switch). The form posts back to the same
# /oauth/authorize URL; Doorkeeper's PreAuthorization picks up `tenant_id`
# from the request params via `custom_access_token_attributes`.
class Views::Oauth::AuthorizationsView < Views::Base
  include Phlex::Rails::Helpers::Routes

  # Public PreAuthorization accessors that need to be re-submitted with the
  # consent form. `client_id` is private on PreAuthorization, so we read it
  # off `pre_auth.client.uid` separately rather than via this list.
  PRE_AUTH_PASSTHROUGH_FIELDS = %i[
    code_challenge code_challenge_method
    response_type response_mode redirect_uri scope state
  ].freeze

  # @param pre_auth [Doorkeeper::OAuth::PreAuthorization]
  # @param application [Doorkeeper::Application] the requesting OAuth client
  # @param tenants [Enumerable<Tenant>] tenants the signed-in user belongs to
  # @param selected_tenant_id [String, nil] currently chosen tenant_id (sticky on re-render)
  # @param error [String, nil] inline error to surface (e.g. invalid tenant)
  def initialize(pre_auth:, application:, tenants:, selected_tenant_id: nil, error: nil)
    @pre_auth = pre_auth
    @application = application
    @tenants = tenants.to_a
    @selected_tenant_id = selected_tenant_id
    @error = error
  end

  def view_template
    div(class: "min-h-screen bg-primary flex items-center justify-center p-4") do
      div(class: "w-full max-w-md") do
        branding
        consent_card
      end
    end
  end

  private

  def branding
    div(class: "text-center mb-8") do
      h1(class: "text-3xl font-bold text-white tracking-tight") { "GrowthOS" }
      p(class: "text-white/70 mt-1 text-sm") { "Authorise an external client" }
    end
  end

  def consent_card
    div(class: "bg-white rounded-2xl shadow-xl p-8") do
      h2(class: "text-lg font-semibold text-gray-900 mb-1") { @application.name }
      p(class: "text-sm text-gray-600 mb-6") { "is requesting access to your GrowthOS account." }

      error_alert
      requested_scopes
      authorize_form
      deny_form
    end
  end

  def error_alert
    return unless @error

    div(
      class: "mb-5 flex items-start gap-2.5 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700",
      role: "alert"
    ) do
      span(class: "mt-0.5 shrink-0", aria: { hidden: "true" }) { "⚠" }
      span { @error }
    end
  end

  def requested_scopes
    div(class: "mb-6") do
      h3(class: "text-xs font-semibold uppercase tracking-wider text-gray-500 mb-2") { "Permissions requested" }
      ul(class: "space-y-1 text-sm text-gray-700") do
        @pre_auth.scopes.each do |scope|
          li(class: "flex items-start gap-2") do
            span(class: "text-primary-ink mt-0.5", aria: { hidden: "true" }) { "•" }
            span { scope_label(scope) }
          end
        end
      end
    end
  end

  def scope_label(scope)
    case scope.to_s
    when "read"  then "Read your frameworks, assessments, and cycles"
    when "write" then "Make changes on your behalf (subject to per-action approval)"
    else scope.to_s
    end
  end

  def authorize_form
    form(
      action: oauth_authorization_path,
      method: :post,
      class: "space-y-4",
      data: { turbo: "false" }
    ) do
      input(type: "hidden", name: "client_id", value: @application.uid)
      passthrough_fields
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      tenant_picker
      authorize_button
    end
  end

  def passthrough_fields
    PRE_AUTH_PASSTHROUGH_FIELDS.each do |field|
      value = @pre_auth.public_send(field)
      next if value.blank?

      input(type: "hidden", name: field.to_s, value: value.to_s)
    end
  end

  def tenant_picker
    div do
      label(
        for: "oauth_tenant_id",
        class: "block text-sm font-medium text-gray-700 mb-1"
      ) { "Workspace" }
      p(class: "text-xs text-gray-500 mb-2") do
        "The access token will only work in the workspace you choose. Re-authorise to switch."
      end
      select(
        id: "oauth_tenant_id",
        name: "tenant_id",
        required: true,
        class: "block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm text-gray-900 focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
      ) do
        option(value: "", disabled: true, selected: @selected_tenant_id.blank?) { "Select a workspace…" }
        @tenants.each do |tenant|
          option(
            value: tenant.id,
            selected: (tenant.id == @selected_tenant_id)
          ) { tenant.name }
        end
      end
    end
  end

  def authorize_button
    button(
      type: "submit",
      class: "w-full rounded-lg bg-primary px-4 py-2.5 text-sm font-semibold text-white hover:bg-secondary focus:outline-none focus:ring-2 focus:ring-primary/50 focus:ring-offset-2 transition-colors"
    ) { "Authorise" }
  end

  def deny_form
    form(
      action: oauth_authorization_path,
      method: :post,
      class: "mt-3",
      data: { turbo: "false" }
    ) do
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "client_id", value: @application.uid)
      passthrough_fields
      button(
        type: "submit",
        class: "w-full rounded-lg border border-gray-300 bg-white px-4 py-2.5 text-sm font-semibold text-gray-700 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-primary/30 transition-colors"
      ) { "Deny" }
    end
  end
end
