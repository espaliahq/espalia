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
  # @param place [String, nil] "mine" or "org" while the switch shows My
  #   feedback or the whole org, carried by every link so it stays that way
  def initialize(conversations:, reads:, viewer_id:, selected_id:, explicit:, place: nil)
    @conversations = conversations
    @reads = reads
    @viewer_id = viewer_id
    @selected_id = selected_id
    @explicit = explicit
    @place = place
    @group = conversations.group
  end

  def view_template
    nav(class: "flex flex-col min-h-0 min-w-0 lg:border-r lg:border-default #{@explicit ? "max-lg:hidden" : ""}",
        aria: { label: "Conversations" }, data: { controller: "conversation-search", testid: "conversation-list" }) do
      div(class: "p-3 space-y-2 border-b border-subtle") do
        input(type: "search", id: "conversation-search", placeholder: "Search people", autocomplete: "off",
              aria: { label: "Search people" }, class: "#{Components::Kit::Field::INPUT} w-full",
              data: { action: "input->conversation-search#filter", conversation_search_target: "input" })
        group_switch
      end
      rows
    end
  end

  private

  def group_switch
    render Components::Kit::SegmentedControl.new(label: "Group conversations", size: :sm, touch: true) do |control|
      [ [ "report", @conversations.about_me? ? "About me" : "By report" ], [ "person", "By person" ] ].each do |group, label|
        control.segment(label, selected: @group == group, href: evidence_hub_path(view: group, place: @place),
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
    render Components::Kit::AttentionDot.new("needs your attention", class: "ml-1.5 align-middle")
  end

  def rows
    list = @conversations.all
    ul(class: "flex-1 min-h-0 overflow-y-auto p-2 space-y-1") do
      if list.empty? && @group == "report" && @conversations.about_me?
        empty_about_me
      elsif list.empty?
        li(class: "p-4 text-sm text-muted") { "No conversations yet. Feedback you give, ask for or receive shows up here." }
      end
      list.each { |c| row(c) }
      li(class: "p-4 text-sm text-muted", hidden: true, data: { conversation_search_target: "empty" }) { "No one matches that name." }
    end
  end

  # About me before anyone has said anything, so its composer is a tap away.
  def empty_about_me
    li(data: { conversation_search_target: "row", name: "about you" }) do
      a(href: conversation_href(@viewer_id, "report", place: @place),
        aria: { current: ("page" if @selected_id == @viewer_id) },
        data: { testid: "conversation-row", person_id: @viewer_id, attention: "false", turbo_prefetch: "false" },
        class: "grid grid-cols-[auto_minmax(0,1fr)] items-center gap-x-3 rounded-xl px-2 py-2 min-h-11 " \
               "hover:bg-default-hover aria-[current=page]:bg-neutral-muted") do
        span(class: "row-span-2") { avatar(@conversations.viewer, size: :sm) }
        span(class: "truncate text-sm font-semibold text-default") { "About you" }
        span(class: "truncate text-xs text-muted") { "Nothing about you yet" }
      end
    end
  end

  def row(conversation)
    person = @conversations.people[conversation.person_id]
    name = if conversation.person_id != @viewer_id then person&.name.to_s
    elsif @group == "report" then "About you"
    else "You"
    end
    current = conversation.person_id == @selected_id
    li(data: { conversation_search_target: "row", name: name.downcase }) do
      a(href: conversation_href(conversation.person_id, @group, place: @place),
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
