# frozen_string_literal: true

# Feedback exchange management view: where the pair stands, the settings and
# write-only secrets form, and the connection test.
#
# Secrets are never rendered: the fields are empty and say whether a value is
# stored. A blank secret on save keeps the stored one.
class Views::Integrations::FeedbackExchangeView < Views::Base
  include Phlex::Rails::Helpers::FormAuthenticityToken
  include Views::Integrations::Concerns::SettingsFields

  # state => [label, Kit::Badge tone]
  STATE_BADGES = {
    not_configured: [ "Not configured", :neutral ],
    missing_secrets: [ "Missing secrets", :warning ],
    disabled: [ "Disabled", :neutral ],
    active: [ "Active", :success ]
  }.freeze

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
    render Components::Shell::TenantAdminLayout.new(
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
        class: "text-sm text-muted hover:text-default transition-colors"
      ) { plain "← Back to Integrations" }

      div(class: "mt-2 flex flex-wrap items-center gap-3") do
        h1(class: "text-2xl font-bold text-default") { "Feedback exchange" }
        label, tone = STATE_BADGES.fetch(state)
        render Components::Kit::Badge.new(label, tone: tone)
      end
      p(class: "mt-1 text-sm text-muted") do
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
    div(class: "mt-6 pt-6 border-t border-default") do
      form(action: test_connection_tenant_feedback_exchange_path, method: "post", class: "flex flex-wrap items-center gap-4") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        render Components::Kit::Button.new(
          variant: :outline, type: :submit, touch: true,
          disabled: state == :not_configured || !@secrets_present["outbound_secret"]
        ) { "Test connection" }
        p(class: "text-xs text-muted max-w-prose") do
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
          error_summary(title: "The settings could not be saved.")
          form(action: tenant_feedback_exchange_path, method: "post", class: "space-y-6") do
            input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
            input(type: "hidden", name: "_method", value: "patch")

            text_field(:peer_name, "Peer name", value: @form_config.peer_name,
                       hint: "A short lowercase slug, such as chip. It labels imported feedback.")
            text_field(:base_url, "Peer address", value: @form_config.base_url, type: "url",
                       placeholder: "https://chip.example.com/api/feedback-exchange",
                       hint: "The peer's exchange address, including its path prefix. It must start with https://.")
            secret_field(:outbound_secret, "Outbound secret", stored: @secrets_present["outbound_secret"],
                         empty_placeholder: "Paste a secret of 32 or more characters",
                         hint: "Signs the requests we send. The peer holds the same value as its inbound secret. At least 32 characters; `openssl rand -hex 32` makes one.")
            secret_field(:inbound_secret, "Inbound secret", stored: @secrets_present["inbound_secret"],
                         empty_placeholder: "Paste a secret of 32 or more characters",
                         hint: "Verifies the requests the peer sends, so it must differ from the outbound secret. At least 32 characters. Replacing it keeps the old value working for 24 hours.")
            kinds_field(:export_kinds, "Types to send", @form_config.export_kinds, FeedbackExchangeConfig::EXPORT_KINDS,
                        hint: "Which types of our feedback the peer may pull. All types includes any type added later. " \
                              "With no box ticked, nothing is sent.")
            kinds_field(:import_kinds, "Types to import", @form_config.import_kinds, FeedbackExchangeConfig::IMPORT_KINDS,
                        hint: "Which types of the peer's feedback we take, matched against the type the peer sends. " \
                              "All types takes whatever it sends. With no box ticked, nothing is imported. " \
                              "\"Any feedback\" matches a peer that sends no finer type.")
            switch_field(:enabled, "Exchange enabled", @form_config.enabled?,
                         hint: "While off, the peer's requests to us are answered 404 and nothing is pulled.")
            inbound_address

            div(class: "flex justify-end") do
              render Components::Kit::Button.new(tone: :brand, type: :submit, touch: true) { "Save settings" }
            end
          end
          disconnect_action if @secrets_present.values.any?
        end
      end
    end
  end

  def disconnect_action
    danger_action(
      modal_id: "feedback-exchange-disconnect-modal", title: "Disconnect the exchange",
      button_label: "Disconnect…", confirm_label: "Disconnect exchange",
      action_path: tenant_feedback_exchange_path,
      description: "Removes both signing secrets and disables the exchange. The peer settings are kept."
    ) do
      p do
        plain "Both signing secrets are removed and the exchange is disabled: the peer's requests are answered 404 " \
              "and nothing is pulled. The peer, address, type lists and cursors stay for a reconnect."
      end
      p do
        plain "The peer still holds its copies of the shared secrets — only its admin can discard them, so tell them."
      end
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
    label(for: id, class: "inline-flex items-center gap-3 min-h-11 text-sm text-default cursor-pointer " \
                          "has-[:disabled]:text-disabled has-[:disabled]:cursor-not-allowed") do
      input(type: "checkbox", id: id, name: "#{field_name(name)}[]", value: kind, checked: checked,
            class: Components::Kit::Field::CHECKBOX, data: data)
      plain label_text
    end
  end

  def kind_label(kind)
    kind == FeedbackExchangeConfig::GENERIC_KIND ? "Any feedback (generic)" : kind.humanize
  end

  def inbound_address
    render Components::Kit::Card.new(variant: :inset) do |card|
      card.body do
        p(class: "text-sm font-medium text-default") { "Our address for the peer" }
        p(class: "mt-1 text-sm font-mono break-all text-default") { @inbound_url }
        p(class: HINT_CLASSES) do
          plain "Give this to the peer as its address for us. It can check the pair with a signed GET to #{@inbound_url}/health."
        end
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
            p(class: "text-sm text-muted") do
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

    div(class: "mt-6 pt-6 border-t border-default") do
      h3(class: "text-sm font-medium text-default") { "Why records were skipped" }
      ul(class: "mt-2 space-y-1 text-sm text-default") do
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

    div(id: "feedback-exchange-unmatched", class: "mt-6 pt-6 border-t border-default") do
      h3(class: "text-sm font-medium text-default") { "People not found in GrowthOS" }
      p(class: HINT_CLASSES) do
        plain "Their feedback waits here and imports on the next sync once GrowthOS has them, matched by their HRIS id or this email."
      end
      ul(class: "mt-2 divide-y divide-default text-sm") do
        @unmatched_people.each do |person|
          li(class: "flex flex-wrap justify-between gap-x-4 py-2") do
            span(class: "min-w-0 [overflow-wrap:anywhere] text-default") do
              plain person[:email]
              span(class: "text-muted") { " · #{person[:display_name]}" } if person[:display_name].present?
            end
            span(class: "text-muted") do
              "#{person[:role] == 'author' ? 'Gave' : 'Received'} #{person[:records]} #{'record'.pluralize(person[:records])}"
            end
          end
        end
      end
    end
  end

  # ── Helpers ──

  def field_prefix = "feedback_exchange"
  def yes_no(value) = value ? "Yes" : "No"
end
