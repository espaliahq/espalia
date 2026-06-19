# frozen_string_literal: true

# The evidence-request hub: incoming requests (respond / decline), outgoing
# requests (cancel), and evidence you've authored (edit / withdraw). The
# surface notifications deep-link to.
class Views::Evidence::HubView < Views::Base
  include Phlex::Rails::Helpers::FormWith

  STATUS_VARIANT = {
    "pending" => :warning, "responded" => :success, "declined" => :default, "cancelled" => :default
  }.freeze

  INPUT_CLASSES = "w-full rounded-md border-gray-300 dark:border-gray-600 dark:bg-gray-900 text-sm " \
                  "focus-visible:ring-primary focus-visible:border-primary"
  FIELD_LABEL_CLASSES = "block text-xs font-medium text-gray-700 dark:text-gray-200 mb-1"

  # @param incoming [Array<EvidenceRequest>] requests addressed to the viewer
  # @param outgoing [Array<EvidenceRequest>] requests the viewer made
  # @param authored [Array<EvidenceItem>] active evidence the viewer authored
  # @param cell_details [Hash{String=>Hash}] request_id => { name:, role:, level_title:, expectation:, illustrations: }
  # @param authored_details [Hash{String=>Hash}] evidence_id => { assessee_name:, capability_name:, role:, level_title:, assignment_id: }
  def initialize(incoming:, outgoing:, authored: [], cell_details: {}, authored_details: {}, user: nil, current_tenant: nil, tenants: [])
    @incoming = incoming
    @outgoing = outgoing
    @authored = authored
    @cell_details = cell_details
    @authored_details = authored_details
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(class: "max-w-3xl mx-auto space-y-10") do
        header
        incoming_section
        outgoing_section
        authored_section
      end
    end
  end

  private

  def header
    div do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Evidence" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        "Requests for evidence addressed to you, ones you've sent, and the evidence you've provided."
      end
    end
  end

  # ── Incoming / outgoing requests ──

  def incoming_section
    section do
      section_heading("Asked of you")
      if @incoming.empty?
        empty("No one has asked you for evidence.")
      else
        div(class: "space-y-4") { @incoming.each { |r| incoming_card(r) } }
      end
    end
  end

  def outgoing_section
    section do
      section_heading("Your requests")
      if @outgoing.empty?
        empty("You haven't requested any evidence yet.")
      else
        div(class: "space-y-4") { @outgoing.each { |r| outgoing_card(r) } }
      end
    end
  end

  def incoming_card(request)
    card(dom_id: request.dom_id) do
      div(class: "text-sm text-gray-900 dark:text-white") do
        plain "#{request.requester&.name || "A colleague"} asked you for evidence"
      end
      request_cell_line(request)
      expectation_block(request)
      message_line(request)
      respond_block(request) if request.pending?
    end
  end

  def outgoing_card(request)
    card(dom_id: request.dom_id) do
      div(class: "flex items-center justify-between gap-3") do
        span(class: "text-sm text-gray-900 dark:text-white") { "To #{request.requestee&.name || "a colleague"}" }
        render Components::Kit::Badge.new(request.status.capitalize, variant: STATUS_VARIANT.fetch(request.status, :default))
      end
      request_cell_line(request)
      expectation_block(request)
      message_line(request)
      if request.pending?
        a(href: evidence_request_path(request), data: { turbo_method: :delete, turbo_confirm: "Cancel this request?" },
          class: "inline-flex items-center min-h-11 text-sm font-medium text-red-700 dark:text-red-400 hover:underline") { "Cancel request" }
      end
    end
  end

  # ── Authored evidence (edit / withdraw) ──

  def authored_section
    section do
      section_heading("Evidence you've provided")
      if @authored.empty?
        empty("You haven't provided any evidence yet.")
      else
        div(class: "space-y-4") { @authored.each { |item| authored_card(item) } }
      end
    end
  end

  def authored_card(item)
    detail = @authored_details.fetch(item.id, {})
    card do
      div do
        p(class: "text-sm font-medium text-gray-900 dark:text-white") { detail[:capability_name] || "Capability" }
        p(class: "text-xs text-gray-600 dark:text-gray-300") { authored_scope_label(item, detail) }
      end
      p(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { authored_type_label(item) }
      p(class: "text-sm text-gray-700 dark:text-gray-200 whitespace-pre-line") { item.content }
      external_link(item)
      authored_actions(item, detail)
    end
  end

  def authored_scope_label(item, detail)
    whose = item.person_id == item.author_id ? "your assessment" : "#{detail[:assessee_name] || "a colleague"}'s assessment"
    level = detail[:level_title].present? ? "#{detail[:level_title]} (Level #{item.level_ordinal})" : "Level #{item.level_ordinal}"
    [ detail[:role], level, "on #{whose}" ].compact.join(" · ")
  end

  def authored_type_label(item)
    item.evidence_type == "other" ? item.custom_type_label.to_s : item.evidence_type.humanize
  end

  def external_link(item)
    url = item.external_reference&.url
    return if url.blank?

    a(href: url, target: "_blank", rel: "noopener",
      class: "inline-flex items-center gap-1 text-sm text-blue-600 hover:underline break-all") do
      plain item.external_reference&.system.presence&.humanize || "Link"
      span(aria: { hidden: "true" }) { " ↗" }
    end
  end

  def authored_actions(item, detail)
    return if detail[:assignment_id].blank?

    div(class: "pt-2 border-t border-gray-100 dark:border-gray-800") do
      details do
        summary(class: "cursor-pointer inline-flex items-center min-h-11 text-sm font-medium text-primary [&::-webkit-details-marker]:hidden") { "Edit" }
        form_with(url: evidence_item_path(item), method: :patch, class: "mt-2 space-y-3", data: { controller: "evidence-response" }) do
          evidence_fields(name_scope: "evidence", id_prefix: "edit-#{item.id}", item: item)
          submit_button("Save changes")
        end
      end
      form_with(url: evidence_item_path(item), method: :delete, class: "mt-1") do
        button(type: "submit", data: { turbo_confirm: "Withdraw this evidence? It will be hidden everywhere it appears." },
               class: "inline-flex items-center min-h-11 text-sm font-medium text-red-700 dark:text-red-400 hover:underline cursor-pointer") { "Withdraw" }
      end
    end
  end

  # ── Shared cell context (requests) ──

  def request_cell_line(request)
    detail = @cell_details.fetch(request.id, {})
    div do
      p(class: "text-sm font-medium text-gray-900 dark:text-white") { detail[:name] || "Capability" }
      p(class: "text-xs text-gray-600 dark:text-gray-300") { request_scope_label(request, detail) }
    end
  end

  def request_scope_label(request, detail)
    level = detail[:level_title].present? ? "#{detail[:level_title]} (Level #{request.level_ordinal})" : "Level #{request.level_ordinal}"
    [ detail[:role], level ].compact.join(" · ")
  end

  # The behavioural expectation (and any role illustrations) for the cell, so
  # the responder sees exactly what behaviour they're evidencing — no lookup.
  def expectation_block(request)
    detail = @cell_details.fetch(request.id, {})
    return if detail[:expectation].blank? && detail[:illustrations].blank?

    div(class: "rounded-md bg-gray-50 dark:bg-gray-800/60 border border-gray-100 dark:border-gray-700 p-3 space-y-2") do
      if detail[:expectation].present?
        div do
          span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "What good looks like" }
          p(class: "mt-0.5 text-sm text-gray-700 dark:text-gray-200") { detail[:expectation] }
        end
      end
      illustrations_list(detail[:illustrations]) if detail[:illustrations].present?
    end
  end

  def illustrations_list(illustrations)
    div do
      span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "Examples for this role" }
      ul(class: "mt-1 space-y-1") do
        illustrations.each do |text|
          li(class: "flex gap-2 text-sm text-gray-700 dark:text-gray-200") do
            span(class: "text-gray-400 dark:text-gray-500", aria: { hidden: "true" }) { "•" }
            span { text }
          end
        end
      end
    end
  end

  def message_line(request)
    return if request.message.blank?

    p(class: "text-sm text-gray-700 dark:text-gray-200 italic") { "“#{request.message}”" }
  end

  # ── Respond form (incoming) ──

  def respond_block(request)
    div(class: "pt-3 border-t border-gray-100 dark:border-gray-800 space-y-3") do
      form_with(url: respond_evidence_request_path(request), method: :post, class: "space-y-3",
                data: { controller: "evidence-response" }) do
        evidence_fields(name_scope: "evidence_request", id_prefix: "respond-#{request.id}")
        submit_button("Provide evidence")
      end
      decline_form(request)
    end
  end

  def decline_form(request)
    form_with(url: decline_evidence_request_path(request), method: :post, scope: :evidence_request, class: "flex items-center gap-2") do |f|
      f.text_field(:reason, placeholder: "Reason (optional)",
                   class: "flex-1 rounded-md border-gray-300 dark:border-gray-600 dark:bg-gray-900 text-sm", aria: { label: "Decline reason" })
      f.submit("Decline",
               class: "inline-flex items-center min-h-11 px-3 rounded-md border border-gray-300 dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-200 cursor-pointer")
    end
  end

  # ── Shared evidence field set (respond + edit) ──

  # @param name_scope [String] the params key ("evidence_request" | "evidence")
  # @param id_prefix [String] unique DOM-id prefix (so multiple forms coexist)
  # @param item [EvidenceItem, nil] pre-fill source when editing
  def evidence_fields(name_scope:, id_prefix:, item: nil)
    selected_type = item&.evidence_type.presence || "peer_feedback"
    type_field(name_scope:, id_prefix:, selected: selected_type)
    custom_label_field(name_scope:, id_prefix:, value: item&.custom_type_label, show: selected_type == "other")
    title_field(name_scope:, id_prefix:, value: item&.title)
    content_field(name_scope:, id_prefix:, value: item&.content)
    external_reference_fields(name_scope:, id_prefix:,
      system: item&.external_reference&.system, url: item&.external_reference&.url)
  end

  def type_field(name_scope:, id_prefix:, selected:)
    div do
      label(for: "#{id_prefix}-type", class: FIELD_LABEL_CLASSES) { "Type" }
      select(id: "#{id_prefix}-type", name: "#{name_scope}[evidence_type]", class: INPUT_CLASSES,
             data: { evidence_response_target: "typeSelect", action: "change->evidence-response#typeChanged" }) do
        Views::Assessments::Evidence::Form::TYPE_OPTIONS.each do |text, value|
          option(value: value, selected: value == selected) { text }
        end
      end
    end
  end

  def custom_label_field(name_scope:, id_prefix:, value:, show:)
    div(class: (show ? nil : "hidden"), data: { evidence_response_target: "customLabel" }) do
      label(for: "#{id_prefix}-custom-label", class: FIELD_LABEL_CLASSES) { "Describe the type" }
      input(id: "#{id_prefix}-custom-label", type: "text", name: "#{name_scope}[custom_type_label]",
            value: value, maxlength: 60, class: INPUT_CLASSES)
    end
  end

  def title_field(name_scope:, id_prefix:, value:)
    div do
      label(for: "#{id_prefix}-title", class: FIELD_LABEL_CLASSES) { "Title (optional)" }
      input(id: "#{id_prefix}-title", type: "text", name: "#{name_scope}[title]", value: value, maxlength: 120, class: INPUT_CLASSES)
    end
  end

  def content_field(name_scope:, id_prefix:, value:)
    div do
      label(for: "#{id_prefix}-content", class: FIELD_LABEL_CLASSES) { "What happened?" }
      textarea(id: "#{id_prefix}-content", name: "#{name_scope}[content]", rows: 3, required: true,
               placeholder: "Describe what you observed…", class: INPUT_CLASSES) { value }
    end
  end

  def external_reference_fields(name_scope:, id_prefix:, system: nil, url: nil)
    div(class: "grid grid-cols-2 gap-2") do
      div do
        label(for: "#{id_prefix}-ref-system", class: FIELD_LABEL_CLASSES) { "Link to (optional)" }
        select(id: "#{id_prefix}-ref-system", name: "#{name_scope}[external_reference][system]", class: INPUT_CLASSES) do
          Views::Assessments::Evidence::Form::SYSTEM_OPTIONS.each do |text, value|
            option(value: value, selected: value == system) { text }
          end
        end
      end
      div do
        label(for: "#{id_prefix}-ref-url", class: FIELD_LABEL_CLASSES) { "URL" }
        input(id: "#{id_prefix}-ref-url", type: "url", name: "#{name_scope}[external_reference][url]",
              value: url, placeholder: "https://", class: INPUT_CLASSES)
      end
    end
  end

  # ── Chrome ──

  def card(dom_id: nil, &)
    # `target:` highlights the card when reached via a notification deep link
    # (/evidence#evidence-request-<id>).
    div(id: dom_id,
        class: "scroll-mt-20 rounded-lg border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 p-4 space-y-2 " \
               "target:ring-2 target:ring-primary target:border-primary", &)
  end

  def section_heading(text)
    h2(class: "text-lg font-semibold text-gray-900 dark:text-white mb-3") { text }
  end

  def submit_button(label)
    button(type: "submit",
           class: "inline-flex items-center min-h-11 px-4 rounded-md bg-primary text-white text-sm font-medium hover:opacity-90 cursor-pointer") { label }
  end

  def empty(text)
    div(class: "rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") { text }
    end
  end
end
