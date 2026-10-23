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
    div(class: "min-h-screen bg-page flex items-center justify-center p-4") do
      div(class: "w-full max-w-md") do
        branding
        consent_card
      end
    end
  end

  private

  def branding
    div(class: "text-center mb-8") do
      h1(class: "text-3xl font-bold text-default tracking-tight") { "GrowthOS" }
      p(class: "text-muted mt-1 text-sm") { "Authorise an external client" }
    end
  end

  def consent_card
    render Components::Kit::Card.new do |card|
      card.body do
        h2(class: "text-lg font-semibold text-default mb-1") { @application.name }
        p(class: "text-sm text-muted mb-6") { "is requesting access to your GrowthOS account." }

        error_alert
        requested_scopes
        authorize_form
        deny_form
      end
    end
  end

  def error_alert
    return unless @error

    render Components::Kit::Alert.new(tone: :danger, class: "mb-5") { @error }
  end

  def requested_scopes
    div(class: "mb-6") do
      h3(class: "text-xs font-semibold uppercase tracking-wider text-muted mb-2") { "Permissions requested" }
      ul(class: "space-y-1 text-sm text-muted") do
        @pre_auth.scopes.each do |scope|
          li(class: "flex items-start gap-2") do
            span(class: "text-brand mt-0.5", aria: { hidden: "true" }) { "•" }
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
        class: "block text-sm font-medium text-default mb-1"
      ) { "Workspace" }
      p(class: "text-xs text-muted mb-2") do
        "The access token will only work in the workspace you choose. Re-authorise to switch."
      end
      select(
        id: "oauth_tenant_id",
        name: "tenant_id",
        required: true,
        class: Components::Kit::Field::SELECT
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
    render Components::Kit::Button.new(tone: :brand, touch: true, type: :submit, class: "w-full") { "Authorise" }
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
      render Components::Kit::Button.new(variant: :outline, touch: true, type: :submit, class: "w-full") { "Deny" }
    end
  end
end
