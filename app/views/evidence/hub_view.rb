# frozen_string_literal: true

# The evidence-request hub: incoming requests (respond / decline), outgoing
# requests (cancel), and evidence you've authored (edit / withdraw). The
# surface notifications deep-link to.
class Views::Evidence::HubView < Views::Base
  include Phlex::Rails::Helpers::FormWith

  STATUS_VARIANT = {
    "pending" => :warning, "responded" => :success, "declined" => :default, "cancelled" => :default
  }.freeze

  # @param incoming [Array<EvidenceRequest>] requests addressed to the viewer
  # @param outgoing [Array<EvidenceRequest>] requests the viewer made
  # @param authored [Array<EvidenceItem>] active evidence the viewer authored
  # @param cell_details [Hash{String=>Hash}] request_id => { name:, role:, level_title:, expectation:, illustrations: }
  # @param authored_details [Hash{String=>Hash}] evidence_id => { assessee_name:, capability_name:, role:, level_title:, assignment_id: }
  def initialize(incoming:, outgoing:, authored: [], cell_details: {}, authored_details: {}, responses: {}, user: nil, current_tenant: nil, tenants: [])
    @incoming = incoming
    @outgoing = outgoing
    @authored = authored
    @cell_details = cell_details
    @authored_details = authored_details
    @responses = responses
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(data: { controller: "modal evidence-modal", action: "keydown.esc@window->modal#close" }) do
        div(class: "max-w-3xl mx-auto space-y-10") do
          header
          incoming_section
          outgoing_section
          authored_section
        end
        render Views::Evidence::ModalShell.new
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
        plain "#{request.requester&.name || "A colleague"} asked you for evidence#{regarding_suffix(request)}"
      end
      request_cell_line(request)
      message_line(request)
      # No behavioural-expectation block here — the "Provide evidence" modal
      # carries the full cell context when you actually respond.
      respond_actions(request) if request.pending?
    end
  end

  def outgoing_card(request)
    card(dom_id: request.dom_id) do
      div(class: "flex items-center justify-between gap-3") do
        span(class: "text-sm text-gray-900 dark:text-white") { "To #{request.requestee&.name || "a colleague"}#{regarding_suffix(request)}" }
        render Components::Kit::Badge.new(request.status.capitalize, variant: STATUS_VARIANT.fetch(request.status, :default))
      end
      request_cell_line(request)
      message_line(request)
      if request.pending?
        a(href: evidence_request_path(request), data: { turbo_method: :delete, turbo_confirm: "Cancel this request?" },
          class: "inline-flex items-center min-h-11 text-sm font-medium text-red-700 dark:text-red-400 hover:underline") { "Cancel request" }
      elsif request.status == "responded"
        response_card(request)
      elsif request.status == "declined" && request.decline_reason.present?
        p(class: "text-sm text-gray-700 dark:text-gray-200") { "Declined: #{request.decline_reason}" }
      end
    end
  end

  # The evidence the requestee provided, embedded so the requester sees the full
  # response — content, link, and the cells it applies to — and can edit its
  # linkage (content stays read-only; they're not the author).
  def response_card(request)
    response = @responses.fetch(request.id, nil)
    return if response.nil?

    item = response[:item]
    div(class: "rounded-md border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800/40 p-3 space-y-2") do
      div(class: "flex items-center justify-between gap-2") do
        span(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "Response from #{item.author&.name || "a colleague"}" }
        span(class: "text-xs text-gray-600 dark:text-gray-300") { response_type_label(item) }
      end
      p(class: "text-sm text-gray-700 dark:text-gray-200 whitespace-pre-line") { item.content }
      external_link(item)
      applies_to_line(response[:links])
      div do
        button(type: "button", data: modal_trigger_data(mode: "edit", evidence_id: item.id),
               class: "inline-flex items-center min-h-11 text-sm font-medium text-primary cursor-pointer") { "Edit links" }
      end
    end
  end

  def response_type_label(item)
    item.evidence_type == "other" ? item.custom_type_label.to_s : item.evidence_type.humanize
  end

  def applies_to_line(links)
    return if links.blank?

    labels = links.map { |l| [ l[:capability_name], l[:level_code] ].compact.join(" ") }.reject(&:blank?)
    return if labels.empty?

    p(class: "text-xs text-gray-600 dark:text-gray-300") { "Applies to: #{labels.join(" · ")}" }
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
        p(class: "text-sm font-medium text-gray-900 dark:text-white") { detail[:name] || "Capability" }
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
    [ detail[:role], level_short(detail, item.level_ordinal), "on #{whose}" ].compact.join(" · ")
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

    div(class: "pt-2 border-t border-gray-100 dark:border-gray-800 flex items-center gap-4") do
      button(type: "button", data: modal_trigger_data(mode: "edit", evidence_id: item.id),
             class: "inline-flex items-center min-h-11 text-sm font-medium text-primary cursor-pointer") { "Edit" }
      form_with(url: evidence_item_path(item), method: :delete) do
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

  # ", regarding <assessee>" when the request is about someone other than the
  # person who made it (a manager asking on a report's behalf); blank when the
  # requester is asking about their own assessment.
  def regarding_suffix(request)
    return "" if request.person_id == request.requested_by_id

    name = request.assessee&.name
    name.present? ? ", regarding #{name}" : ""
  end

  def request_scope_label(request, detail)
    [ detail[:role], level_short(detail, request.level_ordinal) ].compact.join(" · ")
  end

  # Compact level: the role's level code (e.g. "E3"), falling back to "L<n>".
  def level_short(detail, level_ordinal)
    detail[:level_code].presence || "L#{level_ordinal}"
  end

  def message_line(request)
    return if request.message.blank?

    p(class: "text-sm text-gray-700 dark:text-gray-200 italic") { "“#{request.message}”" }
  end

  # ── Respond / edit (open the unified modal) ──

  def respond_actions(request)
    div(class: "pt-3 border-t border-gray-100 dark:border-gray-800 space-y-3") do
      button(type: "button", data: modal_trigger_data(mode: "respond", request_id: request.id),
             class: "inline-flex items-center min-h-11 px-4 rounded-md bg-primary text-white text-sm font-medium hover:opacity-90 cursor-pointer") { "Provide evidence" }
      decline_form(request)
    end
  end

  # Opens the unified evidence modal (return_to=hub) for a request/item.
  def modal_trigger_data(mode:, request_id: nil, evidence_id: nil)
    data = {
      action: "evidence-modal#load click->modal#open",
      evidence_modal_mode_param: mode,
      evidence_modal_return_to_param: "hub"
    }
    data[:evidence_modal_request_id_param] = request_id if request_id
    data[:evidence_modal_evidence_id_param] = evidence_id if evidence_id
    data
  end

  def decline_form(request)
    form_with(url: decline_evidence_request_path(request), method: :post, scope: :evidence_request, class: "flex items-center gap-2") do |f|
      f.text_field(:reason, placeholder: "Reason (optional)",
                   class: "flex-1 rounded-md border-gray-300 dark:border-gray-600 dark:bg-gray-900 text-sm", aria: { label: "Decline reason" })
      f.submit("Decline",
               class: "inline-flex items-center min-h-11 px-3 rounded-md border border-gray-300 dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-200 cursor-pointer")
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

  def empty(text)
    div(class: "rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") { text }
    end
  end
end
