# frozen_string_literal: true

require "test_helper"

# Recorded feedback fans out to the assessment's own parties — the
# recipient and the manager side — never to the author, never for self
# feedback, and not to a requester the answered notification already covers.
class PersonDevelopment::AsyncHandlers::FeedbackNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @assessee_user = create(:user)
    @manager_user = create(:user)
    @peer_user = create(:user)
    @assessee = create(:person, tenant: @tenant, name: "Alex")
    @manager = create(:person, tenant: @tenant, name: "Morgan")
    @peer = create(:person, tenant: @tenant, name: "Jordan")
    create(:tenant_user, tenant: @tenant, user: @assessee_user, person: @assessee, role: :member)
    create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
    create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)
    @assessee.update!(manager: @manager)

    @framework_id = SecureRandom.uuid_v7
    create(:framework_state, framework_id: @framework_id, name: "Eng")
    cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
    @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
    @handler.assign_to_framework(@assessee.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    @assignment_id = PersonFrameworkAssignment.find_by(person_id: @assessee.id, framework_id: @framework_id).id
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def record!(author:, source:, placed: true, id: SecureRandom.uuid_v7)
    cell = placed ? { capability_stable_id: @cap.stable_id, level_ordinal: 2, valence: "demonstrated" } : {}
    @handler.record_evidence(@assessee.id, @framework_id, id,
      source: source, evidence_type: "peer_feedback", content: "Ran the incident call calmly.",
      author_id: author.id, **cell)
    id
  end

  context "a peer records placed feedback" do
    should "notify the recipient and the manager with the cell, and not the author" do
      perform_enqueued_jobs { record!(author: @peer, source: "peer") }

      assert_empty @peer_user.notifications.reload
      mine = @assessee_user.notifications.reload
      assert_equal 1, mine.size
      assert_equal "Jordan gave you feedback", mine.first.inbox_title
      assert_equal "Critical Thinking · L2 — “Ran the incident call calmly.”", mine.first.inbox_body
      assert_equal "/assessments/#{@assignment_id}?capability=#{@cap.stable_id}&level_ordinal=2", mine.first.inbox_url

      theirs = @manager_user.notifications.reload
      assert_equal 1, theirs.size
      assert_equal "Jordan gave Alex feedback", theirs.first.inbox_title
    end

    should "not notify anyone twice when the job is retried" do
      id = nil
      perform_enqueued_jobs { id = record!(author: @peer, source: "peer") }
      event = Rails.configuration.event_store.read.of_type(PersonDevelopment::Events::EvidenceRecorded)
        .to_a.find { |e| e.data[:evidence_id] == id }
      PersonDevelopment::AsyncHandlers::FeedbackNotifier.new.perform(event)

      assert_equal 1, @assessee_user.notifications.reload.size
      assert_equal 1, @manager_user.notifications.reload.size
    end
  end

  context "a peer records unplaced feedback" do
    should "ask the recipient to place it and link to the hub" do
      id = nil
      perform_enqueued_jobs { id = record!(author: @peer, source: "peer", placed: false) }

      mine = @assessee_user.notifications.reload
      assert_equal "Jordan gave you feedback to place", mine.first.inbox_title
      assert_match(/Not yet placed on a capability/, mine.first.inbox_body)
      assert_equal "/evidence#evidence-item-#{id}", mine.first.inbox_url
      assert_equal "Jordan gave Alex feedback to place", @manager_user.notifications.reload.first.inbox_title
    end
  end

  context "the manager records feedback" do
    should "notify only the recipient" do
      perform_enqueued_jobs { record!(author: @manager, source: "manager") }

      assert_equal 1, @assessee_user.notifications.reload.size
      assert_empty @manager_user.notifications.reload
    end
  end

  context "self feedback" do
    should "notify nobody" do
      perform_enqueued_jobs { record!(author: @assessee, source: "self") }

      assert_empty @assessee_user.notifications.reload
      assert_empty @manager_user.notifications.reload
    end
  end

  # A `def` inside a `context` is invisible to `should` (testing.md), so the
  # request helper lives on the class.
  def request!(level_ordinal:)
    id = SecureRandom.uuid_v7
    @handler.request_evidence(@assessee.id, @framework_id, id,
      requested_by_id: @manager.id, requestee_person_id: @peer.id,
      capability_stable_id: @cap.stable_id, level_ordinal: level_ordinal)
    perform_enqueued_jobs
    @manager_user.notifications.reload.destroy_all
    id
  end

  context "feedback that answers a request" do
    should "leave the requester to the answered notification" do
      request_id = request!(level_ordinal: 2)

      perform_enqueued_jobs do
        @handler.record_evidence_for_request(@assessee.id, @framework_id, request_id, SecureRandom.uuid_v7,
          responded_by_id: @peer.id, source: "peer", evidence_type: "peer_feedback", content: "Answered.",
          author_id: @peer.id, capability_stable_id: @cap.stable_id, level_ordinal: 2, valence: "demonstrated")
      end

      assert_equal 1, @assessee_user.notifications.reload.size
      theirs = @manager_user.notifications.reload
      assert_equal 1, theirs.size
      assert_match(/answered your feedback request/, theirs.first.inbox_title)
    end

    should "still tell a requester about ordinary feedback on the cell they asked about" do
      request!(level_ordinal: 2)

      perform_enqueued_jobs { record!(author: @peer, source: "peer") }

      assert_equal 1, @manager_user.notifications.reload.size
      assert_equal "Jordan gave Alex feedback", @manager_user.notifications.first.inbox_title
    end
  end
end
