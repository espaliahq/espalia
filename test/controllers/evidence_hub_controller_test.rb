# frozen_string_literal: true

require "test_helper"

# The Feedback / Evidence page (#647): "Needs you", the conversations and the
# open thread, read marking, and the links notifications send.
class EvidenceHubControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @assessee_user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Manager")
      @assessee = create(:person, tenant: @tenant, email: @assessee_user.email, name: "Alex Assessee", manager: @manager)
      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Jordan Peer")
      create(:tenant_user, tenant: @tenant, user: @assessee_user, person: @assessee, role: :member)
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      @handler = PersonDevelopment::CommandHandler.new
      @handler.assign_to_framework(@assessee.id, @framework_id, @role.role_id, @level.level_id)
      @unplaced_id = SecureRandom.uuid_v7
      @handler.record_evidence(@assessee.id, @framework_id, @unplaced_id,
        source: "peer", evidence_type: "peer_feedback", content: "Ran the incident call calmly.", author_id: @peer.id)
    end
  end

  def notify!(user, record:)
    event = Noticed::Event.create!(type: "FeedbackReceivedNotifier", record: record, params: { tenant_id: @tenant.id })
    Noticed::Notification.create!(type: "FeedbackReceivedNotifier::Notification", event: event, recipient: user)
  end

  def unplaced_item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(@unplaced_id) }

  def feedback_about_manager!
    ActsAsTenant.with_tenant(@tenant) do
      @handler.assign_to_framework(@manager.id, @framework_id, @role.role_id, @level.level_id)
      SecureRandom.uuid_v7.tap do |id|
        @handler.record_evidence(@manager.id, @framework_id, id, source: "peer", evidence_type: "peer_feedback",
          content: "Kept the planning meeting to the point.", author_id: @peer.id)
      end
    end
  end

  context "without a person record" do
    should "refuse the page" do
      sign_in create(:user)
      get evidence_hub_path
      assert_response :forbidden
    end
  end

  context "giving feedback" do
    should "offer the Give feedback entry and leave the modal closed by default" do
      sign_in @peer_user
      get evidence_hub_path
      assert_response :success
      assert_select "button[data-evidence-modal-mode-param='give']", text: "Give feedback"
      assert_select "[data-controller~='evidence-hub'][data-evidence-hub-auto-open-value='false']"
    end

    should "open the give step on arrival when asked to" do
      sign_in @peer_user
      get evidence_hub_path(give: 1)
      assert_select "[data-evidence-hub-auto-open-value='true']"
    end
  end

  context "needs you" do
    should "ask the assessee to place feedback about them" do
      sign_in @assessee_user
      get evidence_hub_path
      assert_select "#needs-you [data-testid='needs-you-place']", text: /Place Jordan's feedback about you/ do
        assert_select "button[data-evidence-modal-mode-param='edit'][data-evidence-modal-evidence-id-param='#{@unplaced_id}']"
      end
    end

    should "ask the manager to place a report's feedback, linking to the report's thread" do
      sign_in @manager_user
      get evidence_hub_path
      assert_select "#needs-you [data-testid='needs-you-place']", text: /about Alex/ do
        assert_select "a[href=?]", evidence_report_conversation_path(@assessee.id, anchor: EvidenceItem.dom_id(@unplaced_id))
      end
    end

    should "ask a peer to place nothing" do
      sign_in @peer_user
      get evidence_hub_path
      assert_select "#needs-you [data-testid='needs-you-place']", count: 0
      assert_select "#needs-you", text: /Nothing needs you/
    end

    should "list a request to answer with a Respond button" do
      request = ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_request, tenant: @tenant, requester: @manager, requestee: @peer, person_id: @assessee.id,
                                  framework_id: @framework_id)
      end
      sign_in @peer_user
      get evidence_hub_path
      assert_select "#needs-you [data-testid='needs-you-request']", text: /Morgan asked you for feedback/ do
        assert_select "button[data-evidence-modal-request-id-param='#{request.id}']", text: "Respond"
      end
    end
  end

  context "conversations" do
    should "show the assessee a thread with the author, and About me beside By person" do
      sign_in @assessee_user
      get evidence_hub_path
      assert_select "[data-testid='conversation-row'][data-person-id='#{@peer.id}']"
      assert_select "[data-testid='group-report']", text: /About me/
      assert_select "[data-testid='group-person'][aria-current='page']", text: /By person/
      assert_select "#needs-you nav", count: 0
    end

    should "send another person's report thread to their conversation when nobody reports to the viewer" do
      sign_in @assessee_user
      get evidence_report_conversation_path(@peer.id)
      assert_redirected_to evidence_conversation_path(@peer.id)
    end

    should "offer an empty About me with its ask" do
      sign_in @peer_user
      get evidence_hub_path(view: "report")
      assert_select "[data-testid='conversation-row'][data-person-id='#{@peer.id}']", text: /About you/
      assert_select "#conversation-title", text: "About you"
    end

    should "gather what's about the assessee into About me" do
      sign_in @assessee_user
      get evidence_report_conversation_path(@assessee.id)
      assert_select "#conversation-title", text: "About you"
      assert_select "##{EvidenceItem.dom_id(@unplaced_id)}"
      assert_select "[data-testid='conversation-row'][data-person-id='#{@assessee.id}']", text: /About you/
    end

    should "show the author a thread with the person it's about" do
      sign_in @peer_user
      get evidence_hub_path
      assert_select "[data-testid='conversation-row'][data-person-id='#{@assessee.id}']"
    end

    should "show a manager their reports first, and people on ?view=person" do
      sign_in @manager_user
      get evidence_hub_path
      assert_select "[data-testid='group-report'][aria-current='page']"
      assert_select "[data-testid='conversation-row'][data-person-id='#{@assessee.id}']"

      get evidence_hub_path(view: "person")
      assert_select "[data-testid='group-person'][aria-current='page']"
      assert_select "[data-testid='conversation-row'][data-person-id='#{@peer.id}']"
    end

    should "mark a switch that holds something needing attention" do
      sign_in @manager_user
      get evidence_hub_path
      assert_select "[data-testid='group-report'][data-attention='true']"
    end

    should "open a thread with a place action on owed feedback" do
      sign_in @assessee_user
      get evidence_conversation_path(@peer.id)
      assert_select "[data-testid='conversation-thread']" do
        assert_select "h2", text: "Jordan Peer"
        assert_select "##{EvidenceItem.dom_id(@unplaced_id)}" do
          assert_select "button", text: "Place on a capability"
        end
      end
    end

    should "open an empty thread with someone the viewer hasn't talked to" do
      sign_in @assessee_user
      get evidence_conversation_path(@manager.id)
      assert_response :success
      assert_select "[data-testid='conversation-thread']", text: /No feedback with Morgan Manager yet/
    end

    should "ask about a report's newest assessment when they have several" do
      newer = ActsAsTenant.with_tenant(@tenant) do
        create(:person_framework_assignment, tenant: @tenant, person_id: @assessee.id, created_at: 1.minute.from_now)
      end
      sign_in @manager_user
      get evidence_report_conversation_path(@assessee.id)
      assert_select "button[data-request-evidence-assignment-id-param='#{newer.id}']", text: "Ask someone about Alex"
    end

    should "link an answered request to its answer only while the answer shows" do
      answer = ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_item, tenant: @tenant, author: @peer, person_id: @assessee.id, framework_id: @framework_id, source: "peer")
      end
      ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_request, tenant: @tenant, requester: @assessee, requestee: @peer, person_id: @assessee.id,
                                  framework_id: @framework_id, status: "responded", evidence_id: answer.id,
                                  requested_at: 2.days.ago)
      end
      sign_in @assessee_user
      get evidence_conversation_path(@peer.id)
      assert_select "a[href='##{EvidenceItem.dom_id(answer.id)}']", text: "See the answer ↓"

      ActsAsTenant.with_tenant(@tenant) { answer.update!(link_status: "withdrawn") }
      get evidence_conversation_path(@peer.id)
      assert_select "a", text: "See the answer ↓", count: 0
    end

    should "answer 404 for a person outside the workspace" do
      sign_in @assessee_user
      get evidence_conversation_path(SecureRandom.uuid_v7)
      assert_response :not_found
    end
  end

  context "read state" do
    should "mark a thread's notifications read when it is opened by its URL" do
      notification = notify!(@assessee_user, record: unplaced_item)
      sign_in @assessee_user

      get evidence_hub_path
      assert_nil notification.reload.read_at, "the page's own pick of the newest thread doesn't count as reading it"
      assert_select "[data-testid='conversation-row'][data-attention='true']"

      get evidence_conversation_path(@peer.id)
      assert notification.reload.read_at
      assert_select "[data-testid='new-messages']"
    end

    should "not mark a thread read when Turbo only prefetches it" do
      notification = notify!(@assessee_user, record: unplaced_item)
      sign_in @assessee_user

      get evidence_conversation_path(@peer.id), headers: { "X-Sec-Purpose" => "prefetch" }
      assert_response :success
      assert_nil notification.reload.read_at
    end

    should "keep its links out of Turbo's prefetch" do
      sign_in @assessee_user
      get evidence_hub_path
      assert_select "[data-testid='conversation-row'][data-turbo-prefetch='false']"
      assert_select "#needs-you a[data-turbo-prefetch='false']"
    end
  end

  context "links from notifications" do
    should "land a link to feedback about the viewer on About me" do
      sign_in @assessee_user
      get evidence_hub_item_path(@unplaced_id)
      assert_redirected_to evidence_report_conversation_path(@assessee.id, anchor: EvidenceItem.dom_id(@unplaced_id))
    end

    should "land an item link on the thread that holds it" do
      sign_in @peer_user
      get evidence_hub_item_path(@unplaced_id)
      assert_redirected_to evidence_conversation_path(@assessee.id, anchor: EvidenceItem.dom_id(@unplaced_id))
    end

    should "land a manager's link on the report's thread, keeping the org view" do
      sign_in @manager_user
      get evidence_hub_item_path(@unplaced_id, place: "org")
      assert_redirected_to evidence_report_conversation_path(@assessee.id, place: "org", anchor: EvidenceItem.dom_id(@unplaced_id))
    end

    should "land a request link on its thread" do
      request = ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_request, tenant: @tenant, requester: @assessee, requestee: @peer, person_id: @assessee.id,
                                  framework_id: @framework_id)
      end
      sign_in @peer_user
      get evidence_hub_request_path(request.id)
      assert_redirected_to evidence_conversation_path(@assessee.id, anchor: request.dom_id)
    end

    should "ask for the whole thread when the message is older than the part that shows" do
      ActsAsTenant.with_tenant(@tenant) do
        EvidenceHubController::THREAD_LIMIT.times do |n|
          create(:evidence_item, tenant: @tenant, author: @peer, person_id: @assessee.id, framework_id: @framework_id,
                                 source: "peer", recorded_at: (n + 1).minutes.from_now)
        end
      end
      sign_in @assessee_user
      get evidence_hub_item_path(@unplaced_id)
      assert_redirected_to evidence_report_conversation_path(@assessee.id, all: 1, anchor: EvidenceItem.dom_id(@unplaced_id))

      follow_redirect!
      assert_select "##{EvidenceItem.dom_id(@unplaced_id)}"
    end

    should "mark only the messages a thread shows as read" do
      old = notify!(@assessee_user, record: unplaced_item)
      ActsAsTenant.with_tenant(@tenant) do
        EvidenceHubController::THREAD_LIMIT.times do |n|
          create(:evidence_item, tenant: @tenant, author: @peer, person_id: @assessee.id, framework_id: @framework_id,
                                 source: "peer", recorded_at: (n + 1).minutes.from_now)
        end
      end
      sign_in @assessee_user
      get evidence_conversation_path(@peer.id)
      assert_nil old.reload.read_at, "a message the thread doesn't show stays unread"
      assert_select "a", text: "Show 1 earlier message"
    end

    should "send a link to something the viewer can't see to the page" do
      sign_in @peer_user
      get evidence_hub_item_path(SecureRandom.uuid_v7)
      assert_redirected_to evidence_hub_path
    end
  end

  context "with a skip-level report" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @lead = create(:person, tenant: @tenant, name: "Lee Lead", manager: @manager)
        @deep = create(:person, tenant: @tenant, name: "Sky Skiplevel", manager: @lead)
        @handler.assign_to_framework(@deep.id, @framework_id, @role.role_id, @level.level_id)
        @deep_item = SecureRandom.uuid_v7
        @handler.record_evidence(@deep.id, @framework_id, @deep_item,
          source: "peer", evidence_type: "peer_feedback", content: "Found the pool limit.", author_id: @peer.id)
      end
      sign_in @manager_user
    end

    should "list only the team by default, with both counts on the toggle" do
      get evidence_hub_path
      assert_select "#needs-you [data-testid='needs-you-place']", count: 1
      assert_select "#needs-you nav a", text: /My team · 1\z/
      assert_select "#needs-you nav a", text: /My whole org · 2\z/
    end

    should "list the whole org for ?place=org" do
      get evidence_hub_path(place: "org")
      assert_select "#needs-you [data-testid='needs-you-place']", count: 2
    end

    should "offer My feedback, My team and My whole org, each with what waits to be placed" do
      feedback_about_manager!
      get evidence_hub_path
      assert_select "#needs-you nav a", text: /My feedback · 1\z/
      assert_select "#needs-you nav a[aria-current='page']", text: /My team · 2\z/
      assert_select "#needs-you nav a", text: /My whole org · 3\z/
    end

    should "show only the manager's own feedback under My feedback, About me first" do
      about_me = feedback_about_manager!
      get evidence_hub_path(place: "mine")
      assert_select "#needs-you [data-testid='needs-you-place']", count: 1, text: /about you/
      assert_select "[data-testid='group-report'][aria-current='page']", text: /About me/
      assert_select "[data-testid='conversation-row']", count: 1
      assert_select "[data-testid='conversation-row'][data-person-id='#{@manager.id}']", text: /About you/
      assert_select "##{EvidenceItem.dom_id(about_me)}"
    end

    should "open About me under My feedback when the URL asks for it under My team" do
      feedback_about_manager!
      get evidence_report_conversation_path(@manager.id)
      assert_redirected_to evidence_report_conversation_path(@manager.id, place: "mine")
    end

    should "land a link to feedback about the manager on About me" do
      about_me = feedback_about_manager!
      get evidence_hub_item_path(about_me)
      assert_redirected_to evidence_report_conversation_path(@manager.id, place: "mine", anchor: EvidenceItem.dom_id(about_me))
    end

    should "send the switch from a report's thread to My feedback's list" do
      get evidence_report_conversation_path(@assessee.id)
      assert_select "#needs-you nav a[href=?]", "#{evidence_hub_path(view: "report", place: "mine")}#needs-you"
    end

    should "send the switch from About me to the team's list" do
      feedback_about_manager!
      get evidence_report_conversation_path(@manager.id, place: "mine")
      assert_select "#needs-you nav a[href=?]", "#{evidence_hub_path(view: "report")}#needs-you", text: /My team/
    end

    should "list the team's conversations by default, and the whole org's for ?place=org" do
      get evidence_hub_path
      assert_select "[data-testid='conversation-row'][data-person-id='#{@assessee.id}']"
      assert_select "[data-testid='conversation-row'][data-person-id='#{@deep.id}']", count: 0

      get evidence_hub_path(place: "org")
      assert_select "[data-testid='conversation-row'][data-person-id='#{@deep.id}']"
    end

    should "offer the switch while nothing beyond the team waits to be placed" do
      ActsAsTenant.with_tenant(@tenant) do
        @handler.withdraw_evidence(@deep.id, @framework_id, @deep_item, withdrawn_by_id: @peer.id)
      end
      get evidence_hub_path
      assert_select "#needs-you nav a", text: /My whole org · 1\z/
    end

    should "leave the counts off the switch while nothing waits to be placed" do
      ActsAsTenant.with_tenant(@tenant) do
        @handler.withdraw_evidence(@deep.id, @framework_id, @deep_item, withdrawn_by_id: @peer.id)
        @handler.withdraw_evidence(@assessee.id, @framework_id, @unplaced_id, withdrawn_by_id: @peer.id)
      end
      get evidence_hub_path
      assert_select "#needs-you nav a", text: /My team\z/
      assert_select "#needs-you nav a", text: /My whole org\z/
    end

    should "open a thread only the org lists in the org view" do
      get evidence_report_conversation_path(@deep.id)
      assert_redirected_to evidence_report_conversation_path(@deep.id, place: "org")
    end

    should "send the switch from a thread only the org lists to the team's list" do
      get evidence_report_conversation_path(@deep.id, place: "org")
      assert_select "#needs-you nav a[href=?]", "#{evidence_hub_path(view: "report")}#needs-you", text: /My team · 1\z/
    end

    should "keep a person with no thread yet open when switching to the team view" do
      get evidence_conversation_path(@lead.id, place: "org")
      assert_select "#needs-you nav a[href=?]", "#{evidence_conversation_path(@lead.id)}#needs-you"
    end

    should "land the answer to a request about a skip-level report on that report's thread" do
      request = ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_request, tenant: @tenant, requester: @manager, requestee: @peer, person_id: @deep.id,
                                  framework_id: @framework_id, status: "responded", evidence_id: @deep_item)
      end
      get evidence_hub_request_path(request.id)
      assert_redirected_to evidence_report_conversation_path(@deep.id, place: "org", anchor: request.dom_id)
    end

    should "land a link to a message only the org lists in the org view" do
      get evidence_hub_item_path(@deep_item)
      assert_redirected_to evidence_report_conversation_path(@deep.id, place: "org", anchor: EvidenceItem.dom_id(@deep_item))
    end

    should "keep the open thread on the toggle, and the org view on every other link" do
      get evidence_report_conversation_path(@assessee.id, place: "org")
      assert_select "#needs-you nav a[href=?]", "#{evidence_report_conversation_path(@assessee.id)}#needs-you", text: /My team · 1\z/
      assert_select "[data-testid='conversation-row'][href=?]", evidence_report_conversation_path(@assessee.id, place: "org")
      assert_select "[data-testid='group-person'][href=?]", evidence_hub_path(view: "person", place: "org")
    end
  end
end
