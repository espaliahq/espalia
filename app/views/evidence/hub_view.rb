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
  # @param capability_names [Hash{String=>String}] stable_id → capability name
  def initialize(incoming:, outgoing:, capability_names: {}, user: nil, current_tenant: nil, tenants: [])
    @incoming = incoming
    @outgoing = outgoing
    @capability_names = capability_names
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
    label = @capability_names[request.capability_stable_id]
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      plain [ label, "Level #{request.level_ordinal}" ].compact.join(" · ")
    end
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
