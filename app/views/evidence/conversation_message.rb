# frozen_string_literal: true

# One message in a Feedback / Evidence conversation: a request, its reply, a
# decline, or a piece of feedback. The viewer's own messages sit on the
# right, everyone else's on the left. Every action the old hub offered is
# here: respond, decline, nudge, cancel, place, edit, withdraw, edit links.
class Views::Evidence::ConversationMessage < Views::Base
  include Phlex::Rails::Helpers::FormWith
  include Phlex::Rails::Helpers::ButtonTo
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Views::Evidence::Valence
  include Views::Evidence::ConversationChrome

  STATUS_TONE = { "responded" => :success, "declined" => :neutral, "cancelled" => :neutral }.freeze
  STATUS_LABEL = { "responded" => "Answered", "declined" => "Declined", "cancelled" => "Cancelled" }.freeze
  LINK = "inline-flex items-center min-h-11 text-sm font-medium text-brand hover:underline cursor-pointer"
  DANGER_LINK = "inline-flex items-center min-h-11 text-sm font-medium text-danger hover:underline cursor-pointer"

  # @param message [Evidence::Conversations::Message]
  # @param viewer_id [String]
  # @param details [Hash] the thread's lookups (see EvidenceHubController#thread_details)
  def initialize(message:, viewer_id:, details:)
    @message = message
    @viewer_id = viewer_id
    @details = details
    @request = message.request
    @item = message.item
  end

  def view_template
    article(id: @message.dom_id, class: "group scroll-mt-24 flex flex-col gap-1 max-w-[min(38rem,94%)] #{mine? ? "self-end items-end" : "self-start"}",
            data: { testid: "conversation-message", kind: @message.kind, mine: mine?.to_s }) do
      p(class: "px-1 text-xs text-muted") { "#{who(sender_id, sender)} · #{short_date(@message.at)}#{answering_note}" }
      div(class: "w-full rounded-2xl group-target:ring-2 group-target:ring-(--gos-border-strong)") do
        render Components::Kit::Card.new(variant: mine? ? :inset : :default, density: :compact) do |card|
          card.body { div(class: "space-y-2") { body } }
        end
      end
    end
  end

  private

  def mine? = sender_id == @viewer_id

  def sender_id
    case @message.kind
    when :request then @request.requested_by_id
    when :declined then @request.requestee_person_id
    else @item.author_id
    end
  end

  def sender
    case @message.kind
    when :request then @request.requester
    when :declined then @request.requestee
    else @item.author
    end
  end

  def body
    case @message.kind
    when :request then request_body
    when :declined then declined_body
    else item_body
    end
  end

  def kicker(text)
    p(class: "text-xs font-semibold uppercase tracking-wide text-muted") { text }
  end

  def chip(text, tone: :neutral)
    render Components::Kit::Badge.new(text, tone: tone)
  end

  # ── Requests ──

  def request_body
    kicker("Feedback request")
    p(class: "text-sm font-medium text-default") do
      "#{who(@request.requested_by_id, @request.requester)} asked #{whom(@request.requestee_person_id, @request.requestee)} for feedback"
    end
    div(class: "flex flex-wrap gap-1.5 min-w-0") do
      chip(about_label(@request.person_id, @request.assessee))
      chip(cell_label(@details[:cells][@request.id], @request.level_ordinal))
    end
    p(class: "text-sm text-muted italic") { "“#{Prose.to_plain(@request.message)}”" } if @request.message.present?
    @request.pending? ? pending_request : resolved_request
  end

  def pending_request
    due = @request.due_at ? " · due #{@request.due_at.strftime("%a %-d %b")}" : ""
    p(class: "text-sm text-default") { plain "Waiting on #{whom(@request.requestee_person_id, @request.requestee)}"; span(class: "text-muted") { due } }
    div(class: "space-y-0.5", data: { testid: "request-history" }) do
      timeline_line("Requested #{time_ago_in_words(@request.requested_at)} ago")
      @request.reminder_history.each { |entry| timeline_line(reminder_label(entry)) }
    end
    if @request.requestee_person_id == @viewer_id
      respond_actions
    elsif @request.requested_by_id == @viewer_id
      outgoing_actions
    end
  end

  def resolved_request
    status = @request.status
    div(class: "flex flex-wrap items-center gap-2") do
      chip(STATUS_LABEL.fetch(status, status.capitalize), tone: STATUS_TONE.fetch(status, :neutral))
      answer_id = status == "responded" && @request.evidence_id ? EvidenceItem.dom_id(@request.evidence_id) : nil
      answer_id ||= "#{@request.dom_id}-declined" if status == "declined"
      a(href: "##{answer_id}", class: LINK) { "See the answer ↓" } if answer_id
    end
  end

  def timeline_line(text)
    p(class: "text-xs text-muted") { text }
  end

  # @param entry [Hash] { "kind" =>, "at" =>, "by_id" => (manual only) }
  def reminder_label(entry)
    at = begin
      Time.zone.parse(entry["at"].to_s)
    rescue ArgumentError
      nil
    end
    label = case entry["kind"]
    when "due_soon" then "Due-date reminder sent"
    when "manual"
      entry["by_id"] == @request.requested_by_id ? "Nudged by #{whom(entry["by_id"], @request.requester)}" : "Nudged by an admin"
    else "Reminder sent"
    end
    [ label, (at && "#{time_ago_in_words(at)} ago") ].compact.join(" ")
  end

  def respond_actions
    unless @request.person_id == @viewer_id
      p(class: "text-xs text-muted", data: { testid: "visibility-note" }) do
        "Your response will be visible to #{first_name(@request.assessee)}, their managers, and workspace admins."
      end
    end
    div(class: "pt-2 border-t border-subtle flex flex-wrap items-center gap-2") do
      render Components::Kit::Button.new(tone: :brand, touch: true, data: modal_trigger_data(mode: "respond", request_id: @request.id)) do
        "Respond"
      end
      render Components::Kit::Button.new(
        variant: :outline, touch: true,
        data: { action: "click->modal#open", modal_target_id: Views::Evidence::DeclineRequestModal.dom_id_for(@request) }
      ) { "Decline" }
    end
    render Views::Evidence::DeclineRequestModal.new(request: @request)
  end

  def outgoing_actions
    div(class: "pt-2 border-t border-subtle flex flex-wrap items-center gap-x-4") do
      button_to("Send a nudge", nudge_evidence_request_path(@request), class: LINK) if @request.can_nudge?
      a(href: evidence_request_path(@request), data: { turbo_method: :delete, turbo_confirm: "Cancel this request?" },
        class: DANGER_LINK) { "Cancel request" }
    end
  end

  def declined_body
    kicker("Declined")
    reply_quote
    render Components::Kit::Prose.new(@request.decline_reason, class: "text-sm text-default") if @request.decline_reason.present?
  end

  # A reply's link back to the request it answers, which may sit far above.
  def reply_quote
    excerpt = @request.message.present? ? " · “#{Prose.to_plain(@request.message).truncate(70)}”" : ""
    a(href: "##{@request.dom_id}", data: { testid: "reply-quote" },
      class: "block truncate rounded-md border-l-4 border-default bg-neutral-subtle px-2 py-1 text-xs text-muted hover:text-default") do
      "↩ #{who(@request.requested_by_id, @request.requester)} asked on #{short_date(@request.requested_at)}: " \
        "#{cell_label(@details[:cells][@request.id], @request.level_ordinal)}#{excerpt}"
    end
  end

  # ── Feedback and replies ──

  def item_body
    kicker(item_kicker)
    reply_quote if @message.kind == :reply
    div(class: "flex flex-wrap items-center gap-1.5") do
      chip(about_label(@item.person_id, assessee)) unless @item.self_authored?
      placed_chips
      render(Views::Evidence::OriginBadge.new(@item.external_reference, size: :sm)) if @item.external_reference&.imported?
    end
    render Components::Kit::Prose.new(@item.content, class: "text-sm text-default")
    external_link
    suggestion_area
    item_actions
  end

  def item_kicker
    return "Reply" if @message.kind == :reply
    return "Note to self" if @item.self_authored?

    @item.evidence_type == "other" ? @item.custom_type_label.to_s : @item.evidence_type.humanize
  end

  def assessee = @details[:people][@item.person_id]

  def placed_chips
    links = @details[:links].fetch(@item.id, [])
    if links.empty?
      chip("Not placed yet", tone: :warning)
    else
      links.each do |link|
        span(class: "inline-flex max-w-full flex-wrap items-center gap-1") do
          chip([ link[:capability_name], link[:level_code] ].compact.join(" · "))
          valence_badge(link[:valence])
        end
      end
    end
  end

  def external_link
    return if @item.external_reference&.imported?

    url = @item.external_reference&.url
    return if url.blank?

    a(href: url, target: "_blank", rel: "noopener", class: "inline-flex items-center gap-1 text-sm text-link hover:underline break-all") do
      plain @item.external_reference&.system.presence&.humanize || "Link"
      span(aria: { hidden: "true" }) { " ↗" }
    end
  end

  def suggestion_area
    return unless @details[:decidable_ids].include?(@item.id)

    render Views::Evidence::PlacementSuggestions.new(
      item: @item, **@details[:suggestions].fetch(@item.id, Evidence::PlacementSuggestionRows::NONE),
      can_regenerate: @details[:can_regenerate], offer_when_empty: unplaced?
    )
    div(id: Views::Evidence::PlacementSuggestions.status_id_for(@item.id), role: "status", aria: { live: "polite" })
  end

  def unplaced? = @details[:links].fetch(@item.id, []).empty?

  def item_actions
    owed = @details[:owed_ids].include?(@message.dom_id)
    in_situ = @details[:in_situ_paths][@item.id]
    mine = @item.author_id == @viewer_id
    edit_links = !mine && !owed && @details[:linkable_ids].include?(@item.id)
    return unless owed || in_situ || mine || edit_links

    div(class: "pt-2 border-t border-subtle flex flex-wrap items-center gap-x-4") do
      if owed
        button(type: "button", data: modal_trigger_data(mode: "edit", evidence_id: @item.id), class: LINK) { "Place on a capability" }
      end
      a(href: in_situ, class: LINK) { "View in assessment" } if in_situ
      if mine
        button(type: "button", data: modal_trigger_data(mode: "edit", evidence_id: @item.id), class: LINK) { "Edit" }
        form_with(url: evidence_item_path(@item), method: :delete) do
          button(type: "submit", data: { turbo_confirm: "Withdraw this feedback? It will be hidden everywhere it appears." },
                 class: DANGER_LINK) { "Withdraw" }
        end
      elsif edit_links
        button(type: "button", data: modal_trigger_data(mode: "edit", evidence_id: @item.id), class: LINK) { "Edit links" }
      end
    end
  end

  # " · answering Maya's request" on feedback that answers a request the
  # viewer can't see.
  def answering_note
    return "" unless @message.kind == :feedback

    requester = @details[:answering][@item.id]
    requester ? " · answering #{first_name(requester)}'s request" : ""
  end

  # "Ownership · E3".
  def cell_label(cell, level_ordinal)
    cell ||= {}
    [ cell[:name] || "Capability", cell[:level_code].presence || "L#{level_ordinal}" ].join(" · ")
  end
end
