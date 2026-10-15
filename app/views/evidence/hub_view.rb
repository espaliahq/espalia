# frozen_string_literal: true

# The evidence-request hub: open requests (incoming — respond / decline;
# outgoing — nudge / cancel, stalest first, each with its reminder history),
# completed requests, and evidence you've authored (edit / withdraw). The
# surface notifications deep-link to.
class Views::Evidence::HubView < Views::Base
  include Phlex::Rails::Helpers::FormWith
  include Phlex::Rails::Helpers::ButtonTo
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Views::Evidence::Valence

  STATUS_VARIANT = {
    "pending" => :warning, "responded" => :success, "declined" => :default, "cancelled" => :default
  }.freeze

  # @param open_incoming [Array<EvidenceRequest>] pending requests addressed to the viewer, stalest first
  # @param open_outgoing [Array<EvidenceRequest>] pending requests the viewer made, stalest first
  # @param completed_incoming [Array<EvidenceRequest>] resolved requests addressed to the viewer
  # @param completed_outgoing [Array<EvidenceRequest>] resolved requests the viewer made
  # @param authored [Array<EvidenceItem>] active evidence the viewer authored
  # @param cell_details [Hash{String=>Hash}] request_id => { name:, role:, level_title:, expectation:, illustrations: }
  # @param authored_details [Hash{String=>Hash}] evidence_id => { assessee_name:, capability_name:, role:, level_title:, assignment_id: }
  # @param in_situ_paths [Hash{String=>String}] evidence_id => assessment deep link
  #   to the item's first linkage (absent when the viewer may not see it)
  def initialize(open_incoming:, open_outgoing:, completed_incoming: [], completed_outgoing: [],
                 authored: [], cell_details: {}, authored_details: {}, responses: {},
                 in_situ_paths: {}, user: nil, current_tenant: nil, tenants: [])
    @open_incoming = open_incoming
    @open_outgoing = open_outgoing
    @completed_incoming = completed_incoming
    @completed_outgoing = completed_outgoing
    @authored = authored
    @cell_details = cell_details
    @authored_details = authored_details
    @responses = responses
    @in_situ_paths = in_situ_paths
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(data: { controller: "modal evidence-modal", action: "keydown.esc@window->modal#escape" }) do
        div(class: "max-w-3xl mx-auto space-y-10") do
          header
          open_requests_group
          completed_requests_group
        end
        render Views::Evidence::ModalShell.new
      end
    end
  end

  private

  def header
    div do
      h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Feedback / Evidence" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        "Requests for feedback addressed to you, ones you've sent, and the feedback you've provided."
      end
    end
  end

  # ── Open / completed request groups ──

  def open_requests_group
    section do
      group_heading("Open requests")
      div(class: "space-y-8") do
        subsection("Asked of you") do
          if @open_incoming.empty?
            empty("No one is waiting on you.")
          else
            div(class: "space-y-4") { @open_incoming.each { |r| incoming_card(r) } }
          end
        end
        subsection("Your requests") do
          if @open_outgoing.empty?
            empty("You have no open requests.")
          else
            div(class: "space-y-4") { @open_outgoing.each { |r| outgoing_card(r) } }
          end
        end
      end
    end
  end

  def completed_requests_group
    return if @completed_incoming.empty? && @completed_outgoing.empty? && @authored.empty?

    section do
      group_heading("Completed requests")
      div(class: "space-y-8") do
        unless @completed_incoming.empty?
          subsection("Asked of you") do
            div(class: "space-y-4") { @completed_incoming.each { |r| incoming_card(r) } }
          end
        end
        unless @completed_outgoing.empty?
          subsection("Your requests") do
            div(class: "space-y-4") { @completed_outgoing.each { |r| outgoing_card(r) } }
          end
        end
        unless @authored.empty?
          subsection("Feedback / Evidence you've provided") do
            div(class: "space-y-4") { @authored.each { |item| authored_card(item) } }
          end
        end
      end
    end
  end

  def incoming_card(request)
    card(dom_id: request.dom_id) do
      div(class: "flex items-center justify-between gap-3") do
        span(class: "text-sm text-gray-900 dark:text-white") do
          "#{request.requester&.name || "A colleague"} asked you for feedback#{regarding_suffix(request)}"
        end
        status_badge(request) unless request.pending?
      end
      request_cell_line(request)
      message_line(request)
      history_timeline(request)
      # No behavioural-expectation block here — the "Provide feedback / evidence"
      # modal carries the full cell context when you actually respond.
      if request.pending?
        response_visibility_note(request)
        respond_actions(request)
      end
    end
  end

  # Before the requestee writes anything, be explicit about who will read the
  # response: the assessee, their manager chain, and workspace admins (the
  # EvidencePolicy view rules). Skipped when the requestee IS the assessee.
  def response_visibility_note(request)
    return if request.requestee_person_id == request.person_id

    name = request.assessee&.name || "the assessee"
    p(class: "text-xs text-gray-500 dark:text-gray-400", data: { testid: "visibility-note" }) do
      "Your response will be visible to #{name}, their managers, and workspace admins."
    end
  end

  def outgoing_card(request)
    card(dom_id: request.dom_id) do
      div(class: "flex items-center justify-between gap-3") do
        span(class: "text-sm text-gray-900 dark:text-white") { "To #{request.requestee&.name || "a colleague"}#{regarding_suffix(request)}" }
        status_badge(request)
      end
      request_cell_line(request)
      message_line(request)
      history_timeline(request)
      if request.pending?
        outgoing_open_actions(request)
      elsif request.status == "responded"
        response_card(request)
      elsif request.status == "declined" && request.decline_reason.present?
        p(class: "text-sm text-gray-700 dark:text-gray-200") { "Declined: #{Prose.to_plain(request.decline_reason)}" }
      end
    end
  end

  def status_badge(request)
    render Components::Kit::Badge.new(request.status.capitalize, variant: STATUS_VARIANT.fetch(request.status, :default))
  end

  def outgoing_open_actions(request)
    div(class: "pt-2 border-t border-gray-100 dark:border-gray-800 flex items-center gap-4") do
      if request.can_nudge?
        button_to("Send a nudge", nudge_evidence_request_path(request),
          class: "inline-flex items-center min-h-11 text-sm font-medium text-primary-ink hover:underline cursor-pointer")
      end
      a(href: evidence_request_path(request), data: { turbo_method: :delete, turbo_confirm: "Cancel this request?" },
        class: "inline-flex items-center min-h-11 text-sm font-medium text-red-700 dark:text-red-400 hover:underline") { "Cancel request" }
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
      render Components::Kit::Prose.new(item.content, class: "text-sm text-gray-700 dark:text-gray-200")
      external_link(item)
      applies_to_line(response[:links])
      div(class: "flex items-center gap-4") do
        button(type: "button", data: modal_trigger_data(mode: "edit", evidence_id: item.id),
               class: "inline-flex items-center min-h-11 text-sm font-medium text-primary-ink cursor-pointer") { "Edit links" }
        view_in_assessment_link(item)
      end
    end
  end

  def response_type_label(item)
    item.evidence_type == "other" ? item.custom_type_label.to_s : item.evidence_type.humanize
  end

  def applies_to_line(links)
    return if links.blank?

    entries = links.filter_map do |l|
      label = [ l[:capability_name], l[:level_code] ].compact.join(" ")
      [ label, l[:valence] ] if label.present?
    end
    return if entries.empty?

    div(class: "flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-gray-600 dark:text-gray-300") do
      span { "Applies to:" }
      entries.each do |label, valence|
        span(class: "inline-flex items-center gap-1") do
          span { label }
          valence_badge(valence)
        end
      end
    end
  end

  # ── Authored evidence (edit / withdraw) — a Completed subsection ──

  def authored_card(item)
    detail = @authored_details.fetch(item.id, {})
    card do
      div do
        p(class: "text-sm font-medium text-gray-900 dark:text-white") { authored_cell_label(item, detail) }
        p(class: "text-xs text-gray-600 dark:text-gray-300") { authored_scope_label(item, detail) }
      end
      p(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { authored_type_label(item) }
      render Components::Kit::Prose.new(item.content, class: "text-sm text-gray-700 dark:text-gray-200")
      external_link(item)
      authored_actions(item, detail)
    end
  end

  # An item recorded without a cell has no capability to name; say so
  # rather than falling back to a placeholder that reads like one.
  def authored_cell_label(item, detail)
    return "Feedback, not yet placed on a capability" if item.capability_stable_id.nil?

    detail[:name] || "Capability"
  end

  def authored_scope_label(item, detail)
    whose = item.person_id == item.author_id ? "your assessment" : "#{detail[:assessee_name] || "a colleague"}'s assessment"
    level = level_short(detail, item.level_ordinal) if item.level_ordinal
    [ detail[:role], level, "on #{whose}" ].compact.join(" · ")
  end

  def authored_type_label(item)
    item.evidence_type == "other" ? item.custom_type_label.to_s : item.evidence_type.humanize
  end

  # Deep link to the item's first linkage on the assessment, so the feedback
  # can be read in situ — next to the expectation, ratings, and the rest of the
  # cell's evidence. Present only when the viewer may see that assessment (the
  # controller applies AssessmentPolicy#show?), so a peer never gets a dead link.
  def view_in_assessment_link(item)
    path = @in_situ_paths[item.id]
    return if path.blank?

    a(href: path, class: "inline-flex items-center min-h-11 text-sm font-medium text-primary-ink hover:underline") do
      "View in assessment"
    end
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
      view_in_assessment_link(item)
      button(type: "button", data: modal_trigger_data(mode: "edit", evidence_id: item.id),
             class: "inline-flex items-center min-h-11 text-sm font-medium text-primary-ink cursor-pointer") { "Edit" }
      form_with(url: evidence_item_path(item), method: :delete) do
        button(type: "submit", data: { turbo_confirm: "Withdraw this feedback? It will be hidden everywhere it appears." },
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

    p(class: "text-sm text-gray-700 dark:text-gray-200 italic") { "“#{Prose.to_plain(request.message)}”" }
  end

  # On every open request card: the request's life so far — when it was asked
  # (and when it's due) plus each reminder that has gone out, so both parties
  # see the same story without opening an activity trail.
  def history_timeline(request)
    return unless request.pending?

    div(class: "space-y-0.5", data: { testid: "request-history" }) do
      timeline_line("Requested #{time_ago_in_words(request.requested_at)} ago#{due_suffix(request)}")
      request.reminder_history.each { |entry| timeline_line(reminder_entry_label(request, entry)) }
    end
  end

  def timeline_line(text)
    p(class: "text-xs text-gray-500 dark:text-gray-400") { text }
  end

  def due_suffix(request)
    request.due_at.present? ? " · due #{request.due_at.strftime("%a %-d %b")}" : ""
  end

  # @param entry [Hash] { "kind" =>, "at" =>, "by_id" => (manual only) }
  def reminder_entry_label(request, entry)
    at = begin
      Time.zone.parse(entry["at"].to_s)
    rescue ArgumentError
      nil
    end
    ago = at ? "#{time_ago_in_words(at)} ago" : nil
    label = case entry["kind"]
    when "due_soon" then "Due-date reminder sent"
    when "manual" then "Nudged by #{nudger_name(request, entry["by_id"])}"
    else "Reminder sent"
    end
    [ label, ago ].compact.join(" ")
  end

  # The nudger is almost always the requester (already loaded); anyone else
  # with nudge rights is a tenant admin.
  def nudger_name(request, by_id)
    by_id == request.requested_by_id ? (request.requester&.name || "the requester") : "an admin"
  end

  # ── Respond / edit (open the unified modal) ──

  def respond_actions(request)
    div(class: "pt-3 border-t border-gray-100 dark:border-gray-800 flex flex-wrap items-center gap-2") do
      button(type: "button", data: modal_trigger_data(mode: "respond", request_id: request.id),
             class: "inline-flex items-center min-h-11 px-4 rounded-md bg-primary text-white text-sm font-medium hover:opacity-90 cursor-pointer") { "Provide feedback / evidence" }
      button(type: "button",
             data: { action: "click->modal#open", modal_target_id: Views::Evidence::DeclineRequestModal.dom_id_for(request) },
             class: "kit-btn-secondary") { "Decline request" }
    end
    render Views::Evidence::DeclineRequestModal.new(request: request)
  end

  # Opens the unified evidence modal (return_to=hub) for a request/item.
  def modal_trigger_data(mode:, request_id: nil, evidence_id: nil)
    data = {
      action: "evidence-modal#load click->modal#open",
      modal_target_id: "evidence-modal-overlay",
      evidence_modal_mode_param: mode,
      evidence_modal_return_to_param: "hub"
    }
    data[:evidence_modal_request_id_param] = request_id if request_id
    data[:evidence_modal_evidence_id_param] = evidence_id if evidence_id
    data
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

  def group_heading(text)
    h2(class: "text-lg font-semibold text-gray-900 dark:text-white mb-4") { text }
  end

  def subsection(title, &)
    div do
      h3(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300 mb-3") { title }
      yield
    end
  end

  def empty(text)
    div(class: "rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center") do
      p(class: "text-sm text-gray-600 dark:text-gray-300") { text }
    end
  end
end
