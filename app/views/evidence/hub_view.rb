# frozen_string_literal: true

# The evidence-request hub: incoming requests (respond / decline) and outgoing
# requests (cancel). The surface notifications deep-link to.
class Views::Evidence::HubView < Views::Base
  include Phlex::Rails::Helpers::FormWith

  STATUS_VARIANT = {
    "pending" => :warning, "responded" => :success, "declined" => :default, "cancelled" => :default
  }.freeze

  # @param incoming [Array<EvidenceRequest>] requests addressed to the viewer
  # @param outgoing [Array<EvidenceRequest>] requests the viewer made
  # @param cell_details [Hash{String=>Hash}] request_id => { name:, expectation:, illustrations: }
  def initialize(incoming:, outgoing:, cell_details: {}, user: nil, current_tenant: nil, tenants: [])
    @incoming = incoming
    @outgoing = outgoing
    @cell_details = cell_details
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
      end
    end
  end

  private

  def header
    div do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Evidence requests" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        "Requests for evidence addressed to you, and ones you've sent."
      end
    end
  end

  def incoming_section
    section do
      h2(class: "text-lg font-semibold text-gray-900 dark:text-white mb-3") { "Asked of you" }
      if @incoming.empty?
        empty("No one has asked you for evidence.")
      else
        div(class: "space-y-4") { @incoming.each { |r| incoming_card(r) } }
      end
    end
  end

  def outgoing_section
    section do
      h2(class: "text-lg font-semibold text-gray-900 dark:text-white mb-3") { "Your requests" }
      if @outgoing.empty?
        empty("You haven't requested any evidence yet.")
      else
        div(class: "space-y-4") { @outgoing.each { |r| outgoing_card(r) } }
      end
    end
  end

  def incoming_card(request)
    card(request) do
      div(class: "text-sm text-gray-900 dark:text-white") do
        plain "#{request.requester&.name || "A colleague"} asked you for evidence"
      end
      cell_line(request)
      expectation_block(request)
      message_line(request)
      respond_block(request) if request.pending?
    end
  end

  def outgoing_card(request)
    card(request) do
      div(class: "flex items-center justify-between gap-3") do
        span(class: "text-sm text-gray-900 dark:text-white") { "To #{request.requestee&.name || "a colleague"}" }
        render Components::Kit::Badge.new(request.status.capitalize, variant: STATUS_VARIANT.fetch(request.status, :default))
      end
      cell_line(request)
      expectation_block(request)
      message_line(request)
      if request.pending?
        a(href: evidence_request_path(request), data: { turbo_method: :delete, turbo_confirm: "Cancel this request?" },
          class: "inline-flex items-center min-h-11 text-sm font-medium text-red-700 dark:text-red-400 hover:underline") { "Cancel request" }
      end
    end
  end

  def card(request, &)
    div(id: "evidence-request-#{request.id}",
        class: "rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 space-y-2", &)
  end

  def cell_line(request)
    detail = details(request)
    div do
      p(class: "text-sm font-medium text-gray-900 dark:text-white") { detail[:name] || "Capability" }
      p(class: "text-xs text-gray-600 dark:text-gray-300") { scope_label(request, detail) }
    end
  end

  # "Software Engineer · Senior Engineer (Level 3)" — the role the request is
  # scoped to and the level within it.
  def scope_label(request, detail)
    level = detail[:level_title].present? ? "#{detail[:level_title]} (Level #{request.level_ordinal})" : "Level #{request.level_ordinal}"
    [ detail[:role], level ].compact.join(" · ")
  end

  # The behavioural expectation (and any role illustrations) for the cell, so
  # the responder sees exactly what behaviour they're evidencing — no lookup.
  def expectation_block(request)
    detail = details(request)
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

  def details(request)
    @cell_details.fetch(request.id, {})
  end

  def message_line(request)
    return if request.message.blank?

    p(class: "text-sm text-gray-700 dark:text-gray-200 italic") { "“#{request.message}”" }
  end

  # Inline respond form (evidence type + content) plus a decline form.
  def respond_block(request)
    div(class: "pt-2 border-t border-gray-100 dark:border-gray-800 space-y-3") do
      form_with(url: respond_evidence_request_path(request), method: :post, scope: :evidence_request, class: "space-y-2") do |f|
        f.select(:evidence_type, EvidenceItem::EVIDENCE_TYPES.map { |t| [ t.humanize, t ] }, { selected: "peer_feedback" },
                 class: "w-full rounded-md border-gray-300 text-sm", aria: { label: "Evidence type" })
        f.text_area(:content, rows: 3, required: true, placeholder: "Describe what you observed…",
                    class: "w-full rounded-md border-gray-300 text-sm", aria: { label: "Evidence" })
        f.submit("Provide evidence",
                 class: "inline-flex items-center min-h-11 px-4 rounded-md bg-primary text-white text-sm font-medium hover:opacity-90 cursor-pointer")
      end
      form_with(url: decline_evidence_request_path(request), method: :post, scope: :evidence_request, class: "flex items-center gap-2") do |f|
        f.text_field(:reason, placeholder: "Reason (optional)",
                     class: "flex-1 rounded-md border-gray-300 text-sm", aria: { label: "Decline reason" })
        f.submit("Decline",
                 class: "inline-flex items-center min-h-11 px-3 rounded-md border border-gray-300 dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-200 cursor-pointer")
      end
    end
  end

  def empty(text)
    div(class: "rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") { text }
    end
  end
end
