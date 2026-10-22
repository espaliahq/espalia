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

  # @param config [FeedbackExchangeConfig] what is saved; drives the status
  # @param form_config [FeedbackExchangeConfig, nil] what the form shows; defaults
  #   to +config+, differs after a rejected save
  # @param secrets_present [Hash{String => Boolean}] which secrets are stored
  # @param inbound_url [String] the address the peer calls on this app
  # @param can_edit [Boolean]
  # @param errors [Array<String>] validation messages from a failed save
  # @param summary [Hash, nil] {FeedbackExchangeImport.summary}
  # @param unmatched_people [Array<Hash>] {FeedbackExchangeImport.unmatched_people}
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(config:, form_config: nil, secrets_present:, inbound_url:, can_edit: false, errors: [],
                 summary: nil, unmatched_people: [], user: nil, current_tenant: nil, tenants: [])
    @config = config
    @form_config = form_config || config
    @secrets_present = secrets_present
    @inbound_url = inbound_url
    @can_edit = can_edit
    @errors = errors
    @summary = summary
    @unmatched_people = unmatched_people
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
                         hint: "Signs the requests we send. The peer holds the same value as its inbound secret. At least 32 characters; `openssl rand -hex 32` makes one.")
            secret_field(:inbound_secret, "Inbound secret",
                         hint: "Verifies the requests the peer sends, so it must differ from the outbound secret. At least 32 characters. Replacing it keeps the old value working for 24 hours.")
            kinds_field(:export_kinds, "Types to send", @form_config.export_kinds, FeedbackExchangeConfig::EXPORT_KINDS,
                        hint: "Which types of our feedback the peer may pull. All types includes any type added later. " \
                              "With no box ticked, nothing is sent.")
            kinds_field(:import_kinds, "Types to import", @form_config.import_kinds, FeedbackExchangeConfig::IMPORT_KINDS,
                        hint: "Which types of the peer's feedback we take, matched against the type the peer sends. " \
                              "All types takes whatever it sends. With no box ticked, nothing is imported. " \
                              "\"Any feedback\" matches a peer that sends no finer type.")
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
            placeholder: stored ? "Leave blank to keep the stored value" : "Paste a secret of 32 or more characters",
            class: "#{INPUT_CLASSES} mt-1", aria: { describedby: "#{field_id(name)}-hint" })
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end

  # "All types" is a box in the same list, so a browser without JavaScript posts
  # it beside the individual boxes and the controller lets it win. While it is
  # ticked, every individual box shows ticked; the all-kinds controller greys them.
  def kinds_field(name, legend_text, selected, options, hint:)
    all = selected.include?(FeedbackExchangeConfig::ALL_KINDS)
    div(data: { controller: "all-kinds" }) do
      input(type: "hidden", name: "#{field_name(name)}[]", value: "")
      fieldset(aria: { describedby: "#{field_id(name)}-hint" }) do
        legend(class: LABEL_CLASSES) { legend_text }
        kind_checkbox(name, FeedbackExchangeConfig::ALL_KINDS, all, label_text: "All types",
                      data: { all_kinds_target: "all", action: "all-kinds#sync" })
        div(class: "grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4 pl-8") do
          options.each do |kind|
            kind_checkbox(name, kind, all || selected.include?(kind), data: { all_kinds_target: "kind" })
          end
        end
      end
      p(id: "#{field_id(name)}-hint", class: HINT_CLASSES) { hint }
    end
  end

  def kind_checkbox(name, kind, checked, data:, label_text: kind_label(kind))
    id = "#{field_id(name)}_#{kind}"
    label(for: id, class: "inline-flex items-center gap-3 min-h-11 text-sm text-gray-900 dark:text-white cursor-pointer " \
                          "has-[:disabled]:opacity-60 has-[:disabled]:cursor-not-allowed") do
      input(type: "checkbox", id: id, name: "#{field_name(name)}[]", value: kind, checked: checked,
            class: "h-5 w-5 rounded border-gray-300 dark:border-gray-600", data: data)
      plain label_text
    end
  end

  def kind_label(kind)
    kind == FeedbackExchangeConfig::GENERIC_KIND ? "Any feedback (generic)" : kind.humanize
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
    div(class: "rounded-md bg-gray-50 dark:bg-gray-900 px-4 py-3") do
      p(class: "text-sm font-medium text-gray-900 dark:text-white") { "Our address for the peer" }
      p(class: "mt-1 text-sm font-mono break-all text-gray-900 dark:text-white") { @inbound_url }
      p(class: HINT_CLASSES) do
        plain "Give this to the peer as its address for us. It can check the pair with a signed GET to #{@inbound_url}/health."
      end
    end
  end

  # ── Counts ──

  # What a skip reason means to the admin who has to act on it.
  SKIP_REASON_LABELS = {
    "author_unmatched" => "Giver not found in GrowthOS",
    "author_inactive" => "Giver inactive",
    "recipient_unmatched" => "Recipient not found in GrowthOS",
    "recipient_inactive" => "Recipient inactive",
    "self_feedback" => "Feedback on themselves",
    "audience_too_narrow" => "Not shared with the manager line and HR",
    "kind_not_imported" => "A kind of feedback not imported",
    "no_assignment" => "Recipient has no framework assignment",
    "echo" => "Came from GrowthOS",
    "invalid_record" => "Malformed or refused"
  }.freeze

  def counts_section
    div(id: "feedback-exchange-counts") do
      render Components::Kit::SectionHeading.new("Activity", subtitle: "What has crossed between the two systems")
      render Components::Kit::Card.new do |card|
        card.body do
          if crossed?
            render Components::Kit::DescriptionList.new(items: count_items, columns: 4)
            skip_reasons
            unmatched_people
          else
            p(class: "text-sm text-gray-600 dark:text-gray-300") do
              plain "Imported, updated and skipped counts appear here once feedback starts flowing."
            end
          end
        end
      end
    end
  end

  def crossed?
    @summary.present? && @summary.values_at(:imported, :updated, :withdrawn, :skipped).sum.positive?
  end

  def count_items
    [
      { term: "Imported", detail: @summary[:imported].to_s },
      { term: "Updated", detail: @summary[:updated].to_s },
      { term: "Withdrawn", detail: @summary[:withdrawn].to_s },
      { term: "Skipped", detail: @summary[:skipped].to_s }
    ]
  end

  def skip_reasons
    return if @summary[:skip_reasons].blank?

    div(class: "mt-6 pt-6 border-t border-gray-200 dark:border-gray-700") do
      h3(class: "text-sm font-medium text-gray-900 dark:text-white") { "Why records were skipped" }
      ul(class: "mt-2 space-y-1 text-sm text-gray-700 dark:text-gray-200") do
        @summary[:skip_reasons].each do |reason, count|
          li(class: "flex justify-between gap-4", data: { skip_reason: reason }) do
            span { SKIP_REASON_LABELS.fetch(reason, reason.humanize) }
            span(class: "tabular-nums") { count.to_s }
          end
        end
      end
    end
  end

  def unmatched_people
    return if @unmatched_people.empty?

    div(id: "feedback-exchange-unmatched", class: "mt-6 pt-6 border-t border-gray-200 dark:border-gray-700") do
      h3(class: "text-sm font-medium text-gray-900 dark:text-white") { "People not found in GrowthOS" }
      p(class: HINT_CLASSES) do
        plain "Their feedback waits here and imports on the next sync once GrowthOS has them, matched by their HRIS id or this email."
      end
      ul(class: "mt-2 divide-y divide-gray-100 dark:divide-gray-800 text-sm") do
        @unmatched_people.each do |person|
          li(class: "flex flex-wrap justify-between gap-x-4 py-2") do
            span(class: "min-w-0 [overflow-wrap:anywhere] text-gray-900 dark:text-white") do
              plain person[:email]
              span(class: "text-gray-600 dark:text-gray-300") { " · #{person[:display_name]}" } if person[:display_name].present?
            end
            span(class: "text-gray-600 dark:text-gray-300") do
              "#{person[:role] == 'author' ? 'Gave' : 'Received'} #{person[:records]} #{'record'.pluralize(person[:records])}"
            end
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
