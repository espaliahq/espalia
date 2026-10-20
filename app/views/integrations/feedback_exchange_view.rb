# frozen_string_literal: true

# Feedback exchange management view: where the pair stands, the settings and
# write-only secrets form, and the connection test.
#
# Secrets are never rendered: the fields are empty and say whether a value is
# stored. A blank secret on save keeps the stored one.
class Views::Integrations::FeedbackExchangeView < Views::Base
  include Phlex::Rails::Helpers::FormAuthenticityToken

  # state => [label, Kit::Badge variant]
  STATE_BADGES = {
    not_configured: [ "Not configured", :default ],
    missing_secrets: [ "Missing secrets", :warning ],
    disabled: [ "Disabled", :default ],
    active: [ "Active", :success ]
  }.freeze

  INPUT_CLASSES = "block w-full min-h-11 rounded-md border-gray-300 dark:border-gray-600 " \
                  "dark:bg-gray-700 dark:text-white shadow-xs focus:border-primary focus:ring-primary"
  LABEL_CLASSES = "block text-sm font-medium text-gray-900 dark:text-white"
  HINT_CLASSES = "mt-1 text-xs text-gray-600 dark:text-gray-300"
  BUTTON_CLASSES = "inline-flex items-center justify-center min-h-11 px-4 rounded-md text-sm font-medium cursor-pointer " \
                   "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-gray-900 " \
                   "dark:focus-visible:ring-white"
  PRIMARY_BUTTON_CLASSES = "#{BUTTON_CLASSES} bg-gray-900 text-white hover:bg-gray-700 " \
                           "dark:bg-white dark:text-gray-900 dark:hover:bg-gray-200"
  SECONDARY_BUTTON_CLASSES = "#{BUTTON_CLASSES} border border-gray-300 dark:border-gray-600 text-gray-700 " \
                             "dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"

  # @param config [FeedbackExchangeConfig] what is saved; drives the status
  # @param form_config [FeedbackExchangeConfig, nil] what the form shows; defaults
  #   to +config+, differs after a rejected save
  # @param secrets_present [Hash{String => Boolean}] which secrets are stored
  # @param inbound_url [String] the address the peer calls on this app
  # @param can_edit [Boolean]
  # @param errors [Array<String>] validation messages from a failed save
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(config:, form_config: nil, secrets_present:, inbound_url:, can_edit: false, errors: [],
                 user: nil, current_tenant: nil, tenants: [])
    @config = config
    @form_config = form_config || config
    @secrets_present = secrets_present
    @inbound_url = inbound_url
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
        counts_section
      end
    end
  end

  private

  def state
    @state ||= @config.state(secrets_complete: @secrets_present.values.all?)
  end

  def page_header
    div(class: "mb-6") do
      a(
        href: tenant_integrations_path,
        class: "text-sm text-gray-600 dark:text-gray-300 hover:underline"
      ) { plain "← Back to Integrations" }

      div(class: "mt-2 flex flex-wrap items-center gap-3") do
        h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Feedback exchange" }
        label, variant = STATE_BADGES.fetch(state)
        render Components::Kit::Badge.new(label, variant: variant)
      end
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        plain "Share named feedback with another feedback system. Each side pulls the other's feed, " \
              "and every request is signed with a secret the two systems share."
      end
    end
  end

  # ── Status ──

  def status_section
    div do
      render Components::Kit::SectionHeading.new("Connection", subtitle: "Where this pair stands")

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
      { term: "Peer", detail: @config.peer_name.presence || "—" },
      { term: "Peer address", detail: @config.base_url.presence || "—" },
      { term: "Exchange enabled", detail: yes_no(@config.enabled?) },
      { term: "Last synced", detail: @config.last_synced_at&.to_fs(:long) || "Never" },
      { term: "Outbound secret", detail: stored_label(@secrets_present["outbound_secret"]) },
      { term: "Inbound secret", detail: stored_label(@secrets_present["inbound_secret"]) }
    ]
  end

  def test_connection_form
    div(class: "mt-6 pt-6 border-t border-gray-200 dark:border-gray-700") do
      form(action: test_connection_tenant_feedback_exchange_path, method: "post", class: "flex flex-wrap items-center gap-4") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        button(type: "submit", class: SECONDARY_BUTTON_CLASSES, disabled: state == :not_configured || !@secrets_present["outbound_secret"]) do
          "Test connection"
        end
        p(class: "text-xs text-gray-600 dark:text-gray-300 max-w-prose") do
          plain "Sends a signed request to the peer's /health with the outbound secret. " \
                "It works before the exchange is enabled."
        end
      end
    end
  end

  # ── Settings ──

  def settings_section
    div do
      render Components::Kit::SectionHeading.new(
        "Settings",
        subtitle: "Stored secrets are never shown. Leave a secret blank to keep it."
      )

      render Components::Kit::Card.new do |card|
        card.body do
          error_summary
          form(action: tenant_feedback_exchange_path, method: "post", class: "space-y-6") do
            input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
            input(type: "hidden", name: "_method", value: "patch")

            text_field(:peer_name, "Peer name", value: @form_config.peer_name,
                       hint: "A short lowercase slug, such as chip. It labels imported feedback.")
            text_field(:base_url, "Peer address", value: @form_config.base_url, type: "url",
                       placeholder: "https://chip.example.com/api/feedback-exchange",
                       hint: "The peer's exchange address, including its path prefix. It must start with https://.")
            secret_field(:outbound_secret, "Outbound secret",
                         hint: "Signs the requests we send. The peer holds the same value as its inbound secret.")
            secret_field(:inbound_secret, "Inbound secret",
                         hint: "Verifies the requests the peer sends. Replacing it keeps the old value working for 24 hours.")
            enabled_field
            inbound_address

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

  def text_field(name, label_text, value:, hint:, type: "text", placeholder: nil)
    div do
      label(for: field_id(name), class: LABEL_CLASSES) { label_text }
      input(type: type, id: field_id(name), name: field_name(name), value: value.to_s, placeholder: placeholder,
            autocomplete: "off", class: "#{INPUT_CLASSES} mt-1", aria: { describedby: "#{field_id(name)}-hint" })
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end

  def secret_field(name, label_text, hint:)
    stored = @secrets_present[name.to_s]
    div do
      label(for: field_id(name), class: LABEL_CLASSES) do
        plain label_text
        span(class: "ml-2 text-xs font-normal text-gray-600 dark:text-gray-300") { stored ? "Stored" : "Not set" }
      end
      input(type: "password", id: field_id(name), name: field_name(name), value: "", autocomplete: "new-password",
            placeholder: stored ? "Leave blank to keep the stored value" : "Paste a 32+ character secret",
            class: "#{INPUT_CLASSES} mt-1", aria: { describedby: "#{field_id(name)}-hint" })
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end

  def enabled_field
    div do
      input(type: "hidden", name: field_name(:enabled), value: "0")
      label(class: "inline-flex items-center gap-3 min-h-11 text-sm font-medium text-gray-900 dark:text-white cursor-pointer") do
        input(type: "checkbox", id: field_id(:enabled), name: field_name(:enabled), value: "1", checked: @form_config.enabled?,
              class: "h-5 w-5 rounded border-gray-300 dark:border-gray-600", aria: { describedby: "#{field_id(:enabled)}-hint" })
        plain "Exchange enabled"
      end
      p(id: "#{field_id(:enabled)}-hint", class: HINT_CLASSES) do
        plain "While off, the peer's requests to us are answered 404 and nothing is pulled."
      end
    end
  end

  def inbound_address
    div(class: "rounded-md bg-gray-50 dark:bg-gray-800/50 px-4 py-3") do
      p(class: "text-sm font-medium text-gray-900 dark:text-white") { "Our address for the peer" }
      p(class: "mt-1 text-sm font-mono break-all text-gray-900 dark:text-white") { @inbound_url }
      p(class: HINT_CLASSES) do
        plain "Give this to the peer as its address for us. It can check the pair with a signed GET to #{@inbound_url}/health."
      end
    end
  end

  # ── Counts ──

  def counts_section
    div(id: "feedback-exchange-counts") do
      render Components::Kit::SectionHeading.new("Activity", subtitle: "What has crossed between the two systems")
      render Components::Kit::Card.new do |card|
        card.body do
          p(class: "text-sm text-gray-600 dark:text-gray-300") do
            plain "Imported, updated and skipped counts appear here once feedback starts flowing."
          end
        end
      end
    end
  end

  # ── Helpers ──

  def field_id(name) = "feedback_exchange_#{name}"
  def field_name(name) = "feedback_exchange[#{name}]"
  def yes_no(value) = value ? "Yes" : "No"
  def stored_label(value) = value ? "Stored" : "Not set"
end
