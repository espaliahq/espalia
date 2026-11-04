# frozen_string_literal: true

# One open conversation: who it's with, its messages oldest to newest with a
# "New" line before the first unread one, and the composer. On a phone it is
# its own screen, with a link back to the list.
class Views::Evidence::ConversationThread < Views::Base
  include Views::Evidence::ConversationChrome

  # @param partner [Person] the other party, the report, or the viewer for notes to self
  # @param viewer_id [String]
  # @param group [String] "person" or "report"
  # @param details [Hash] see EvidenceHubController#thread_details
  # @param new_keys [Set<String>] read keys that were unread when the thread opened
  # @param explicit [Boolean] whether the URL named this thread (false when
  #   the page opened the newest one itself)
  # @param place [String, nil] "org" while "Needs you" shows the whole org
  def initialize(partner:, viewer_id:, group:, details:, new_keys:, explicit:, place: nil)
    @partner = partner
    @viewer_id = viewer_id
    @group = group
    @details = details
    @new_keys = new_keys
    @explicit = explicit
    @place = place
  end

  def view_template
    section(class: "flex flex-col min-h-0 min-w-0 #{@explicit ? "" : "max-lg:hidden"}", aria: { labelledby: "conversation-title" },
            data: { controller: "conversation-thread", conversation_thread_explicit_value: @explicit.to_s,
                    testid: "conversation-thread" }) do
      header
      body
      composer
    end
  end

  private

  def report_thread? = @group == "report"
  def self_thread? = @partner.id == @viewer_id

  def header
    div(class: "max-lg:sticky max-lg:top-0 max-lg:z-10 flex items-center gap-3 px-4 py-3 border-b border-subtle bg-default",
        data: { testid: "conversation-header" }) do
      a(href: evidence_hub_path(view: @group, place: @place), class: "lg:hidden inline-flex items-center gap-1 min-h-11 pr-1 text-sm font-medium text-brand") do
        span(aria: { hidden: "true" }) { "←" }
        plain "Conversations"
      end
      avatar(@partner)
      div(class: "min-w-0") do
        h2(id: "conversation-title", class: "text-base font-semibold text-default truncate") { title }
        p(class: "text-xs text-muted truncate") { subtitle }
      end
    end
  end

  def title = self_thread? ? "You" : @partner.name

  def subtitle
    return "Notes about your own work" if self_thread?
    return "Everything about #{first_name(@partner)}" if report_thread?

    @partner.job_title.presence || ""
  end

  def body
    messages = @details[:messages] || []
    div(class: "flex-1 min-h-0 lg:overflow-y-auto bg-page px-4 py-4 flex flex-col gap-4",
        data: { conversation_thread_target: "body" }) do
      if messages.empty?
        render Components::Kit::EmptyState.new(title: "No feedback with #{title} yet. Start below.")
      else
        # A short thread sits at the bottom, next to the composer, as in a
        # messaging app; a long one still scrolls from its top.
        div(class: "mt-auto flex flex-col gap-4") do
          earlier_link
          first_new = messages.find { |m| (m.read_keys & @new_keys.to_a).any? }
          messages.each do |message|
            new_line if message.equal?(first_new)
            render Views::Evidence::ConversationMessage.new(message: message, viewer_id: @viewer_id, details: @details)
          end
        end
      end
    end
  end

  def earlier_link
    hidden = @details[:hidden_count].to_i
    return unless hidden.positive?

    a(href: conversation_href(@partner.id, @group, all: 1, place: @place), class: "self-center inline-flex items-center min-h-11 text-sm font-medium text-brand hover:underline") do
      "Show #{hidden} earlier #{hidden == 1 ? "message" : "messages"}"
    end
  end

  def new_line
    div(role: "separator", aria: { label: "New messages" }, data: { testid: "new-messages" },
        class: "flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-brand " \
               "before:h-px before:flex-1 before:bg-(--gos-border-brand) after:h-px after:flex-1 after:bg-(--gos-border-brand)") do
      "New"
    end
  end

  def composer
    c = @details[:composer] || {}
    div(class: "border-t border-default bg-default px-4 py-3 space-y-2", data: { conversation_thread_target: "composer" }) do
      p(class: "text-xs text-muted") do
        "Not a private chat. Feedback is visible to the person it's about, their managers and workspace admins."
      end
      div(class: "flex flex-wrap gap-2") do
        c[:self_thread] ? self_actions(c) : partner_actions(c)
      end
    end
  end

  def self_actions(c)
    return p(class: "text-sm text-muted") { "Add notes from your assessment." } unless c[:own_assessment_path]

    render Components::Kit::Button.new(tone: :brand, touch: true, href: c[:own_assessment_path]) { "Add a note on your assessment" }
  end

  def partner_actions(c)
    if c[:can_give]
      data = c[:give_assignment_id] ? modal_trigger_data(mode: "new", assignment_id: c[:give_assignment_id]) : modal_trigger_data(mode: "give")
      render Components::Kit::Button.new(tone: :brand, touch: true, data: data) { "Give #{first_name(@partner)} feedback" }
    end
    return unless c[:ask_assignment_id]

    render Components::Kit::Button.new(
      variant: :outline, touch: true,
      data: { action: "request-evidence#load click->modal#open", modal_target_id: "evidence-request-modal-overlay",
              request_evidence_assignment_id_param: c[:ask_assignment_id],
              request_evidence_requestee_id_param: c[:ask_requestee_id] }.compact
    ) { report_thread? ? "Ask someone about #{first_name(@partner)}" : "Ask #{first_name(@partner)} for feedback" }
  end
end
