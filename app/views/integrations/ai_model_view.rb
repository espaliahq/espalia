# frozen_string_literal: true

# AI model management view: where the tenant's model stands, the settings and
# write-only key form, and the connection test.
#
# The key is never rendered: the field is empty and says whether a value is
# stored. A blank key on save keeps the stored one.
class Views::Integrations::AiModelView < Views::Base
  include Phlex::Rails::Helpers::FormAuthenticityToken
  include Views::Integrations::Concerns::SettingsFields

  # state => [label, Kit::Badge tone]
  STATE_BADGES = {
    not_configured: [ "Not configured", :neutral ],
    disabled: [ "Suggestions off", :neutral ],
    active: [ "Active", :success ]
  }.freeze

  PROVIDER_LABELS = {
    "anthropic" => "Anthropic API",
    "openai_compatible" => "OpenAI-compatible",
    "typesafe_jev" => "Jev (TypeSafe AI)"
  }.freeze

  # @param config [AiModelConfig] what is saved; drives the status
  # @param form_config [AiModelConfig, nil] what the form shows; defaults to
  #   +config+, differs after a rejected save
  # @param state [Symbol] one of {STATE_BADGES}
  # @param key_stored [Boolean] whether an API key is available to the model,
  #   the deployment's included: what the status card reports
  # @param key_field_stored [Boolean, nil] whether a key was stored through this
  #   form, which is the only one a blank field keeps; defaults to +key_stored+
  # @param can_edit [Boolean]
  # @param errors [Array<String>] validation messages from a failed save
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(config:, state:, key_stored:, key_field_stored: nil, form_config: nil, can_edit: false, errors: [],
                 user: nil, current_tenant: nil, tenants: [])
    @config = config
    @form_config = form_config || config
    @state = state
    @key_stored = key_stored
    @key_field_stored = key_field_stored.nil? ? key_stored : key_field_stored
    @can_edit = can_edit
    @errors = errors
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :integrations,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-4xl mx-auto space-y-10") do
        page_header
        status_section
        settings_section if @can_edit
      end
    end
  end

  private

  def page_header
    div(class: "mb-6") do
      a(
        href: tenant_integrations_path,
        class: "text-sm text-muted hover:text-default transition-colors"
      ) { plain "← Back to Integrations" }

      div(class: "mt-2 flex flex-wrap items-center gap-3") do
        h1(class: "text-2xl font-bold text-default") { "AI model" }
        label, tone = STATE_BADGES.fetch(@state)
        render Components::Kit::Badge.new(label, tone: tone)
      end
      p(class: "mt-1 text-sm text-muted") do
        plain "The model that suggests where recorded feedback belongs. Choose the provider, address and model, " \
              "and give it a key. Nothing is sent until suggestions are switched on."
      end
    end
  end

  # ── Status ──

  def status_section
    div do
      render Components::Kit::SectionHeading.new("Connection", subtitle: "What this workspace uses today")

      render Components::Kit::Card.new do |card|
        card.body do
          render Components::Kit::DescriptionList.new(items: status_items, columns: 3)
          test_connection_form if @can_edit
        end
      end
    end
  end

  def status_items
    [
      { term: "Provider", detail: PROVIDER_LABELS.fetch(@config.provider) },
      { term: "Address", detail: @config.base_host || (@config.anthropic? ? "Anthropic API" : "—") },
      { term: "Model", detail: @config.model.presence || (@config.anthropic? ? AiModelConfig::DEFAULT_ANTHROPIC_MODEL : "—") },
      { term: "Suggestions", detail: @config.suggestions_enabled? ? "On" : "Off" },
      { term: "API key", detail: @key_stored ? "Stored" : "Not set" }
    ]
  end

  def test_connection_form
    div(class: "mt-6 pt-6 border-t border-default") do
      form(action: test_connection_tenant_ai_model_path, method: "post", class: "flex flex-wrap items-center gap-4") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        render Components::Kit::Button.new(variant: :outline, type: :submit, touch: true,
                                           disabled: @state == :not_configured) { "Test connection" }
        p(class: "text-xs text-muted max-w-prose") do
          plain "Sends the saved model one short request and shows what it answers. It works before suggestions are switched on."
        end
      end
    end
  end

  # ── Settings ──

  def settings_section
    div do
      render Components::Kit::SectionHeading.new(
        "Settings",
        subtitle: "A stored key is never shown. Leave the key blank to keep it."
      )

      render Components::Kit::Card.new do |card|
        card.body do
          error_summary(title: "The settings could not be saved.")
          form(action: tenant_ai_model_path, method: "post", class: "space-y-6",
               data: { controller: "ai-model-preset", ai_model_preset_presets_value: presets_json }) do
            input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
            input(type: "hidden", name: "_method", value: "patch")

            preset_field
            provider_field
            text_field(:base_url, "Address", value: @form_config.base_url, type: "url",
                       data: { ai_model_preset_target: "baseUrl" },
                       placeholder: "https://ai-gateway.vercel.sh/v1",
                       hint: "Required for an OpenAI-compatible endpoint, the address that serves /chat/completions, " \
                             "and for Jev, the address that serves /evaluate. Optional for Anthropic, where it points " \
                             "the API at a compatible endpoint, without /v1. It must start with https://.")
            text_field(:model, "Model", value: @form_config.model, data: { ai_model_preset_target: "model" },
                       placeholder: AiModelConfig::DEFAULT_ANTHROPIC_MODEL,
                       hint: "The provider's or gateway's model id, such as claude-opus-5-5, or #{AiModelConfig::JEV_MODEL} on the gateway.")
            secret_field(:api_key, "API key", stored: @key_field_stored,
                         empty_placeholder: "Paste the provider's or gateway's key",
                         hint: "Stored encrypted and only ever sent to the address above. It is never shown again.")
            effort_field
            switch_field(:suggestions_enabled, "Suggest where feedback belongs", @form_config.suggestions_enabled?,
                         hint: "While on, feedback goes to this model when it is recorded or edited, self feedback included, " \
                               "so it can suggest capabilities and levels. The names of people in this workspace are always swapped for " \
                               "placeholders first and restored in the answer. A nickname or someone outside the " \
                               "workspace is sent as written, and so are roles and the story itself.")

            div(class: "flex justify-end") do
              render Components::Kit::Button.new(tone: :brand, type: :submit, touch: true) { "Save settings" }
            end
          end
          remove_key_action if @key_field_stored
        end
      end
    end
  end

  def remove_key_action
    danger_action(
      modal_id: "ai-key-remove-modal", title: "Remove the API key",
      button_label: "Remove key…", confirm_label: "Remove API key",
      action_path: tenant_ai_model_path,
      description: "Removes the stored key and switches suggestions off."
    ) do
      p do
        plain "The stored key is removed and suggestions switch off with it. " \
              "The provider, address and model stay; save a new key to switch suggestions back on."
      end
    end
  end

  def presets_json
    AiModelConfig::PRESETS.transform_values { |preset| preset.slice(:provider, :base_url, :model) }.to_json
  end

  def current_preset
    config = @form_config
    on_gateway = config.normalized_base_url == AiModelConfig::VERCEL_AI_GATEWAY_URL
    return on_gateway ? "vercel_ai_gateway" : "typesafe_jev" if config.typesafe_jev?
    return "vercel_ai_gateway_chat" if on_gateway
    return config.base_url.present? ? "anthropic_compatible" : "anthropic" if config.anthropic?

    "openai_compatible"
  end

  def preset_field
    div do
      label(for: "ai_model_preset", class: LABEL_CLASSES) { "Preset" }
      select(id: "ai_model_preset", class: SELECT_CLASSES, autocomplete: "off",
             data: { ai_model_preset_target: "preset", action: "change->ai-model-preset#apply" },
             aria: { describedby: "ai_model_preset-hint" }) do
        AiModelConfig::PRESETS.each do |key, preset|
          option(value: key, selected: key == current_preset) { preset[:label] }
        end
      end
      p(id: "ai_model_preset-hint", class: HINT_CLASSES) do
        plain "Fills the fields below. On Vercel's AI Gateway, Jev is a decision model: it picks the likeliest cells " \
              "and says how sure it is, but writes no reason. A chat model writes one."
      end
    end
  end

  def provider_field
    select_field(:provider, "Provider",
                 data: { ai_model_preset_target: "provider", action: "change->ai-model-preset#providerChanged" }) do
      PROVIDER_LABELS.each do |value, label_text|
        option(value: value, selected: value == @form_config.provider) { label_text }
      end
    end
  end

  def effort_field
    div(data: { ai_model_preset_target: "effortRow" }, hidden: !@form_config.anthropic?) do
      label(for: field_id(:effort), class: LABEL_CLASSES) { "Effort" }
      select(id: field_id(:effort), name: field_name(:effort), class: SELECT_CLASSES, autocomplete: "off",
             aria: { describedby: "#{field_id(:effort)}-hint" }) do
        AiModelConfig::EFFORTS.each { |value| option(value: value, selected: value == @form_config.effort) { value.capitalize } }
        option(value: "", selected: @form_config.effort.blank?) { "Don't send" }
      end
      p(id: "#{field_id(:effort)}-hint", class: HINT_CLASSES) do
        plain "How hard an Anthropic model thinks before it answers. Low is right for placement suggestions; higher costs more and takes longer. " \
              "Choose Don't send for a model that rejects the setting, such as Claude Haiku 4.5."
      end
    end
  end

  # ── Helpers ──

  def field_prefix = "ai_model"
end
