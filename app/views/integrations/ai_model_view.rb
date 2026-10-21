# frozen_string_literal: true

# AI model management view: where the tenant's model stands, the settings and
# write-only key form, and the connection test.
#
# The key is never rendered: the field is empty and says whether a value is
# stored. A blank key on save keeps the stored one.
class Views::Integrations::AiModelView < Views::Base
  include Phlex::Rails::Helpers::FormAuthenticityToken

  # state => [label, Kit::Badge variant]
  STATE_BADGES = {
    not_configured: [ "Not configured", :default ],
    disabled: [ "Suggestions off", :default ],
    active: [ "Active", :success ]
  }.freeze

  PROVIDER_LABELS = {
    "anthropic" => "Anthropic API",
    "openai_compatible" => "OpenAI-compatible",
    "typesafe_jev" => "Jev (TypeSafe AI)"
  }.freeze

  INPUT_CLASSES = "block w-full min-h-11 rounded-md border-gray-300 dark:border-gray-600 " \
                  "dark:bg-gray-700 dark:text-white shadow-xs focus:border-primary focus:ring-primary " \
                  "placeholder:text-gray-600 dark:placeholder:text-gray-300"
  LABEL_CLASSES = "block text-sm font-medium text-gray-900 dark:text-white"
  HINT_CLASSES = "mt-1 text-xs text-gray-600 dark:text-gray-300 [overflow-wrap:anywhere]"
  BUTTON_CLASSES = "inline-flex items-center justify-center min-h-11 px-4 rounded-md text-sm font-medium cursor-pointer " \
                   "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-gray-900 " \
                   "dark:focus-visible:ring-white"
  PRIMARY_BUTTON_CLASSES = "#{BUTTON_CLASSES} bg-gray-900 text-white hover:bg-gray-700 " \
                           "dark:bg-white dark:text-gray-900 dark:hover:bg-gray-200"
  SECONDARY_BUTTON_CLASSES = "#{BUTTON_CLASSES} border border-gray-300 dark:border-gray-600 text-gray-700 " \
                             "dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"

  # @param config [AiModelConfig] what is saved; drives the status
  # @param form_config [AiModelConfig, nil] what the form shows; defaults to
  #   +config+, differs after a rejected save
  # @param state [Symbol] one of {STATE_BADGES}
  # @param key_stored [Boolean] whether an API key is available
  # @param can_edit [Boolean]
  # @param errors [Array<String>] validation messages from a failed save
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(config:, state:, key_stored:, form_config: nil, can_edit: false, errors: [],
                 user: nil, current_tenant: nil, tenants: [])
    @config = config
    @form_config = form_config || config
    @state = state
    @key_stored = key_stored
    @can_edit = can_edit
    @errors = errors
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::TenantAdminLayout.new(
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
        class: "text-sm text-gray-600 dark:text-gray-300 hover:underline"
      ) { plain "← Back to Integrations" }

      div(class: "mt-2 flex flex-wrap items-center gap-3") do
        h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "AI model" }
        label, variant = STATE_BADGES.fetch(@state)
        render Components::Kit::Badge.new(label, variant: variant)
      end
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
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
      { term: "Names hidden", detail: @config.pseudonymise_names? ? "Yes" : "No" },
      { term: "API key", detail: @key_stored ? "Stored" : "Not set" }
    ]
  end

  def test_connection_form
    div(class: "mt-6 pt-6 border-t border-gray-200 dark:border-gray-700") do
      form(action: test_connection_tenant_ai_model_path, method: "post", class: "flex flex-wrap items-center gap-4") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        button(type: "submit", class: SECONDARY_BUTTON_CLASSES, disabled: @state == :not_configured) { "Test connection" }
        p(class: "text-xs text-gray-600 dark:text-gray-300 max-w-prose") do
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
          error_summary
          form(action: tenant_ai_model_path, method: "post", class: "space-y-6",
               data: { controller: "ai-model-preset", ai_model_preset_presets_value: presets_json }) do
            input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
            input(type: "hidden", name: "_method", value: "patch")

            preset_field
            provider_field
            text_field(:base_url, "Address", value: @form_config.base_url, type: "url", target: "baseUrl",
                       placeholder: "https://ai-gateway.vercel.sh/v1",
                       hint: "Required for an OpenAI-compatible endpoint, the address that serves /chat/completions, " \
                             "and for Jev, the address that serves /evaluate. Optional for Anthropic, where it points " \
                             "the API at a compatible endpoint, without /v1. It must start with https://.")
            text_field(:model, "Model", value: @form_config.model, target: "model", placeholder: AiModelConfig::DEFAULT_ANTHROPIC_MODEL,
                       hint: "The provider's or gateway's model id, such as claude-opus-5-5, or #{AiModelConfig::JEV_MODEL} on the gateway.")
            key_field
            effort_field
            switch_field(:suggestions_enabled, "Suggest where feedback belongs", @form_config.suggestions_enabled?,
                         hint: "While on, recorded feedback goes to this model so it can suggest capabilities and levels. Self feedback never does.")
            switch_field(:pseudonymise_names, "Hide people's names from the model", @form_config.pseudonymise_names?,
                         hint: "Names of people in this workspace are swapped for placeholders on the way out and restored in the answer. " \
                               "The mapping is not stored. It hides names, not roles or the story itself.")

            div(class: "flex justify-end") do
              button(type: "submit", class: PRIMARY_BUTTON_CLASSES) { "Save settings" }
            end
          end
        end
      end
    end
  end

  def error_summary
    return if @errors.empty?

    div(role: "alert", class: "mb-6 rounded-md border border-red-300 dark:border-red-700 bg-red-50 dark:bg-red-900/20 " \
                              "px-4 py-3 text-sm text-red-800 dark:text-red-200") do
      p(class: "font-medium") { "The settings could not be saved." }
      ul(class: "mt-1 list-disc pl-5") { @errors.each { |message| li { message } } }
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
      select(id: "ai_model_preset", class: "#{INPUT_CLASSES} mt-1", autocomplete: "off",
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
    div do
      label(for: field_id(:provider), class: LABEL_CLASSES) { "Provider" }
      select(id: field_id(:provider), name: field_name(:provider), class: "#{INPUT_CLASSES} mt-1", autocomplete: "off",
             data: { ai_model_preset_target: "provider", action: "change->ai-model-preset#providerChanged" }) do
        PROVIDER_LABELS.each do |value, label_text|
          option(value: value, selected: value == @form_config.provider) { label_text }
        end
      end
    end
  end

  def text_field(name, label_text, value:, hint:, target:, type: "text", placeholder: nil)
    div do
      label(for: field_id(name), class: LABEL_CLASSES) { label_text }
      input(type: type, id: field_id(name), name: field_name(name), value: value.to_s, placeholder: placeholder,
            autocomplete: "off", class: "#{INPUT_CLASSES} mt-1", data: { ai_model_preset_target: target },
            aria: { describedby: "#{field_id(name)}-hint" })
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end

  def key_field
    div do
      label(for: field_id(:api_key), class: LABEL_CLASSES) do
        plain "API key"
        span(class: "ml-2 text-xs font-normal text-gray-600 dark:text-gray-300") { @key_stored ? "Stored" : "Not set" }
      end
      input(type: "password", id: field_id(:api_key), name: field_name(:api_key), value: "", autocomplete: "new-password",
            placeholder: @key_stored ? "Leave blank to keep it" : "Paste the provider's or gateway's key",
            class: "#{INPUT_CLASSES} mt-1", aria: { describedby: "#{field_id(:api_key)}-hint" })
      p(id: "#{field_id(:api_key)}-hint", class: HINT_CLASSES) do
        plain "Stored encrypted and only ever sent to the address above. It is never shown again."
      end
    end
  end

  def effort_field
    div(data: { ai_model_preset_target: "effortRow" }, hidden: !@form_config.anthropic?) do
      label(for: field_id(:effort), class: LABEL_CLASSES) { "Effort" }
      select(id: field_id(:effort), name: field_name(:effort), class: "#{INPUT_CLASSES} mt-1", autocomplete: "off",
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

  def switch_field(name, label_text, checked, hint:)
    div do
      input(type: "hidden", name: field_name(name), value: "0")
      label(class: "inline-flex items-center gap-3 min-h-11 text-sm font-medium text-gray-900 dark:text-white cursor-pointer") do
        input(type: "checkbox", id: field_id(name), name: field_name(name), value: "1", checked: checked,
              class: "h-5 w-5 rounded border-gray-300 dark:border-gray-600", aria: { describedby: "#{field_id(name)}-hint" })
        plain label_text
      end
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end

  # ── Helpers ──

  def field_id(name) = "ai_model_#{name}"
  def field_name(name) = "ai_model[#{name}]"
end
