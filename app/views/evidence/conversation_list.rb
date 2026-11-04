# frozen_string_literal: true

# The conversations, the most recently active first. A dot on a row, or on
# the By report / By person switch, means it needs the viewer's attention:
# something to answer or place, or a message they haven't read.
class Views::Evidence::ConversationList < Views::Base
  include Views::Evidence::ConversationChrome

  # @param conversations [Evidence::Conversations]
  # @param reads [Evidence::ConversationReads]
  # @param viewer_id [String]
  # @param selected_id [String, nil] the person whose thread is open
  # @param explicit [Boolean] whether a thread is open on its own URL (the
  #   list then gives the screen to it on a phone)
  def initialize(conversations:, reads:, viewer_id:, selected_id:, explicit:)
    @conversations = conversations
    @reads = reads
    @viewer_id = viewer_id
    @selected_id = selected_id
    @explicit = explicit
    @group = conversations.group
  end

  def view_template
    nav(class: "flex flex-col min-h-0 min-w-0 lg:border-r lg:border-default #{@explicit ? "max-lg:hidden" : ""}",
        aria: { label: "Conversations" }, data: { controller: "conversation-search", testid: "conversation-list" }) do
      div(class: "p-3 space-y-2 border-b border-subtle") do
        input(type: "search", id: "conversation-search", placeholder: "Search people", autocomplete: "off",
              aria: { label: "Search people" }, class: "#{Components::Kit::Field::INPUT} w-full",
              data: { action: "input->conversation-search#filter", conversation_search_target: "input" })
        group_switch if @conversations.reports?
      end
      rows
    end
  end

  private

  def group_switch
    render Components::Kit::SegmentedControl.new(label: "Group conversations", size: :sm, touch: true) do |control|
      [ [ "report", "By report" ], [ "person", "By person" ] ].each do |group, label|
        control.segment(label, selected: @group == group, href: evidence_hub_path(view: group),
                               marked: ("needs your attention" if attention_in?(group)),
                               data: { testid: "group-#{group}", attention: attention_in?(group).to_s })
      end
    end
  end

  def attention_in?(group)
    (@attention ||= {})[group] ||= @conversations.all(group: group).any? { |c| attention?(c) }
  end

  def attention?(conversation)
    conversation.owes || conversation.messages.any? { |m| @reads.unread?(m) }
  end

  def attention_dot
    span(class: "ml-1 text-xs text-default", aria: { hidden: "true" }) { "●" }
    span(class: "sr-only") { " (needs your attention)" }
  end

  def rows
    list = @conversations.all
    ul(class: "flex-1 min-h-0 overflow-y-auto p-2 space-y-1") do
      if list.empty?
        li(class: "p-4 text-sm text-muted") { "No conversations yet. Feedback you give, ask for or receive shows up here." }
      end
      list.each { |c| row(c) }
      li(class: "p-4 text-sm text-muted", hidden: true, data: { conversation_search_target: "empty" }) { "No one matches that name." }
    end
  end

  def row(conversation)
    person = @conversations.people[conversation.person_id]
    name = conversation.person_id == @viewer_id ? "You" : person&.name.to_s
    current = conversation.person_id == @selected_id
    li(data: { conversation_search_target: "row", name: name.downcase }) do
      a(href: conversation_href(conversation.person_id, @group),
        aria: { current: (current ? "page" : nil) },
        data: { testid: "conversation-row", person_id: conversation.person_id, attention: attention?(conversation).to_s,
                turbo_prefetch: "false" },
        class: "grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-3 rounded-xl px-2 py-2 min-h-11 " \
               "hover:bg-default-hover aria-[current=page]:bg-neutral-muted") do
        span(class: "row-span-2") { avatar(person, size: :sm) }
        span(class: "truncate text-sm font-semibold text-default") do
          plain name
          attention_dot if attention?(conversation)
        end
        span(class: "text-xs text-muted tabular-nums") { short_date(conversation.last_at) }
        span(class: "truncate text-xs text-muted") { preview(conversation.latest) }
        span(class: "justify-self-end") do
          render Components::Kit::Badge.new("Waiting", tone: :neutral) if conversation.waiting
        end
      end
    end
  end

  def preview(message)
    case message.kind
    when :request
      r = message.request
      return "Request cancelled" if r.status == "cancelled"

      r.requested_by_id == @viewer_id ? "You asked for feedback" : "#{first_name(r.requester)} asked you for feedback"
    when :declined then "#{who(message.request.requestee_person_id, message.request.requestee)} declined"
    else "#{who(message.item.author_id, message.item.author)}: #{Prose.to_plain(message.item.content).truncate(90)}"
    end
  end
end
