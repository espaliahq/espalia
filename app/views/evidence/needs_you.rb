# frozen_string_literal: true

# What the viewer owes, oldest first: requests to answer and feedback to place
# (about them, and for a manager about their team or whole org). Underneath,
# the people the viewer is waiting on. Unread messages don't appear here:
# they mark their conversation instead.
class Views::Evidence::NeedsYou < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Views::Evidence::ConversationChrome

  # @param needs [Hash] see EvidenceHubController#needs_you
  # @param viewer_id [String]
  # @param hidden_on_phone [Boolean] whether a thread has the screen on a phone
  def initialize(needs:, viewer_id:, hidden_on_phone:)
    @needs = needs
    @viewer_id = viewer_id
    @hidden_on_phone = hidden_on_phone
  end

  def view_template
    rows = owed_rows
    section(id: "needs-you", aria: { labelledby: "needs-you-title" }, data: { testid: "needs-you" },
            class: "scroll-mt-20 #{@hidden_on_phone ? "max-lg:hidden" : ""}") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex flex-wrap items-center justify-between gap-2") do
            h2(id: "needs-you-title", class: "text-base font-semibold text-default") do
              plain "Needs you"
              span(class: "ml-2 align-middle") { render Components::Kit::Badge.new(rows.size.to_s, tone: rows.any? ? :brand : :neutral) }
            end
            place_toggle if @needs[:place_counts]
          end
          if rows.empty?
            p(class: "mt-2 text-sm text-muted") { "Nothing needs you. Requests and feedback to place show up here." }
          else
            ul(class: "mt-2 divide-y divide-(--gos-border-subtle)") { rows.each { |row| row.call } }
          end
          waiting_line
        end
      end
    end
  end

  private

  # Requests and feedback to place, merged oldest first.
  def owed_rows
    requests = @needs[:incoming].map { |r| [ r.last_reminded_at || r.requested_at, -> { request_row(r) } ] }
    items = (@needs[:about_you] + @needs[:for_team]).map { |item| [ item.recorded_at, -> { place_row(item) } ] }
    (requests + items).sort_by(&:first).map(&:last)
  end

  def request_row(request)
    li(class: "flex flex-wrap items-center gap-x-3 gap-y-1 py-2", data: { testid: "needs-you-request" }) do
      row_link(@needs[:paths][request.id], request.requester) do
        span(class: "block text-sm font-medium text-default") { "#{first_name(request.requester)} asked you for feedback" }
        span(class: "block text-xs text-muted") do
          regarding = request.person_id == request.requested_by_id ? "" : "About #{first_name(request.assessee)} · "
          due = request.due_at ? " · due #{request.due_at.strftime("%a %-d %b")}" : ""
          "#{regarding}Asked #{time_ago_in_words(request.requested_at)} ago#{due}"
        end
      end
      render Components::Kit::Button.new(tone: :brand, size: :sm, data: modal_trigger_data(mode: "respond", request_id: request.id)) do
        "Respond"
      end
    end
  end

  def place_row(item)
    count = @needs[:suggestion_counts][item.id].to_i
    li(class: "flex flex-wrap items-center gap-x-3 gap-y-1 py-2", data: { testid: "needs-you-place" }) do
      row_link(@needs[:paths][item.id], item.author) do
        about = item.person_id == @viewer_id ? "about you" : "about #{first_name(@needs[:people][item.person_id])}"
        span(class: "block text-sm font-medium text-default") { "Place #{first_name(item.author)}'s feedback #{about}" }
        span(class: "block text-xs text-muted") do
          parts = [ "Given #{time_ago_in_words(item.recorded_at)} ago" ]
          parts << "#{count} #{count == 1 ? "suggestion" : "suggestions"}" if count.positive?
          parts << "imported" if item.external_reference&.imported?
          parts.join(" · ")
        end
      end
      render Components::Kit::Button.new(tone: :brand, size: :sm, data: modal_trigger_data(mode: "edit", evidence_id: item.id)) do
        "Place"
      end
    end
  end

  def row_link(href, person, &)
    classes = "flex flex-1 min-w-64 items-center gap-3 rounded-lg p-1 min-h-11"
    if href
      a(href: href, class: "#{classes} hover:bg-default-hover", data: { turbo_prefetch: "false" }) do
        avatar(person, size: :sm)
        span(class: "min-w-0", &)
      end
    else
      div(class: classes) do
        avatar(person, size: :sm)
        span(class: "min-w-0", &)
      end
    end
  end

  def waiting_line
    waiting = @needs[:waiting]
    return if waiting.empty?

    div(class: "mt-3 flex flex-wrap items-center gap-x-3 text-xs text-muted", data: { testid: "waiting-on" }) do
      span { "Waiting on others:" }
      waiting.each do |request|
        a(href: @needs[:paths][request.id] || "#", class: "inline-flex items-center min-h-6 font-medium text-brand hover:underline",
          data: { turbo_prefetch: "false" }) do
          "#{first_name(request.requestee)} · #{time_ago_in_words(request.requested_at)}"
        end
      end
    end
  end

  # Plain links, so the view is in the URL (?place=org) and works without
  # JavaScript; the counts of feedback to place say there is more without
  # switching. The switch scopes the conversations too.
  def place_toggle
    counts = @needs[:place_counts]
    nav(aria: { label: "Whose feedback to show" }) do
      render Components::Kit::SegmentedControl.new(size: :sm, touch: true) do |control|
        control.segment("My team · #{counts[:team]}", href: "#{@needs[:scope_paths]["team"]}#needs-you",
                                                      selected: @needs[:place_scope] != "org")
        control.segment("My whole org · #{counts[:org]}", href: "#{@needs[:scope_paths]["org"]}#needs-you",
                                                          selected: @needs[:place_scope] == "org")
      end
    end
  end
end
