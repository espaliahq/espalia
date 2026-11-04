# frozen_string_literal: true

# The Feedback / Evidence page: "Needs you" on top, then the
# conversations beside the open thread. On a phone the list and the thread
# are separate screens: the page shows the list, a thread's own URL shows
# the thread.
class Views::Evidence::HubView < Views::Base
  include Views::Evidence::ConversationChrome

  # @param conversations [Evidence::Conversations]
  # @param reads [Evidence::ConversationReads]
  # @param selected [Evidence::Conversations::Conversation, nil] the open thread
  # @param partner [Person, nil] whom the open thread is with or about
  # @param explicit [Boolean] whether the URL named the thread
  # @param new_keys [Set<String>] read keys that were unread when it opened
  # @param thread [Hash] see EvidenceHubController#thread_details
  # @param needs [Hash] see EvidenceHubController#needs_you
  # @param open_give_step [Boolean] open "Give feedback" on arrival (`?give=1`, a Slack draft)
  # @param draft [FeedbackDraft, nil]
  def initialize(conversations:, reads:, selected:, partner:, explicit:, new_keys:, thread:, needs:,
                 open_give_step: false, draft: nil, user: nil, current_tenant: nil, tenants: [])
    @conversations = conversations
    @reads = reads
    @selected = selected
    @partner = partner
    @explicit = explicit
    @new_keys = new_keys
    @thread = thread
    @needs = needs
    @open_give_step = open_give_step
    @draft = draft
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @viewer_id = conversations.viewer.id
  end

  def view_template
    render Components::Shell::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(data: { controller: "modal evidence-modal request-evidence evidence-hub",
                  evidence_hub_auto_open_value: @open_give_step.to_s,
                  action: "keydown.esc@window->modal#escape" }) do
        div(class: "max-w-6xl mx-auto space-y-6") do
          header
          render Views::Evidence::NeedsYou.new(needs: @needs, viewer_id: @viewer_id, hidden_on_phone: @explicit)
          conversations
        end
        render Views::Evidence::ModalShell.new
        render Views::Evidence::RequestModalShell.new
      end
    end
  end

  private

  def header
    div(class: "flex flex-wrap items-start justify-between gap-3 #{@explicit ? "max-lg:hidden" : ""}") do
      div(class: "flex-1 min-w-64") do
        h1(class: "text-2xl font-bold text-default") { "Feedback / Evidence" }
        p(class: "mt-1 text-sm text-muted") { "What needs you, then every conversation, newest first." }
      end
      # The hub controller clicks this same button when the page arrives with
      # ?give=1 or a Slack draft, so the two paths can't drift.
      render Components::Kit::Button.new(tone: :brand, touch: true,
                                         data: give_trigger_data.merge(evidence_hub_target: "autoTrigger")) do
        "Give feedback"
      end
    end
  end

  # The give step; with a Slack draft, straight to its recipient's form when
  # the draft names one, filled from it either way.
  def give_trigger_data
    if @draft&.assignment_id
      modal_trigger_data(mode: "new").merge(evidence_modal_assignment_id_param: @draft.assignment_id,
                                            evidence_modal_draft_token_param: @draft.token)
    elsif @draft
      modal_trigger_data(mode: "give").merge(evidence_modal_draft_token_param: @draft.token)
    else
      modal_trigger_data(mode: "give")
    end
  end

  def place = ("org" if @needs[:place_scope] == "org")

  def conversations
    div(class: "lg:grid lg:grid-cols-[20rem_minmax(0,1fr)] lg:h-[min(80vh,52rem)] " \
               "rounded-2xl border border-default bg-default shadow-raised overflow-clip") do
      render Views::Evidence::ConversationList.new(
        conversations: @conversations, reads: @reads, viewer_id: @viewer_id,
        selected_id: @partner&.id, explicit: @explicit, place: place
      )
      if @partner
        render Views::Evidence::ConversationThread.new(
          partner: @partner, viewer_id: @viewer_id, group: @conversations.group,
          details: @thread, new_keys: @new_keys, explicit: @explicit, place: place
        )
      else
        div(class: "max-lg:hidden grid place-items-center p-8") do
          render Components::Kit::EmptyState.new(title: "Conversations appear here once you give, ask for or receive feedback.")
        end
      end
    end
  end
end
