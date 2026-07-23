# frozen_string_literal: true

require "test_helper"

# Verifies a posted assessment comment fans out to the conversation's other
# parties — reply → parent author, comment → assessee, assessee's comment →
# manager side — with one notification per recipient and the author excluded.
class PersonDevelopment::AsyncHandlers::CommentNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @assessee_user = create(:user)
    @manager_user = create(:user)
    @assessee = create(:person, tenant: @tenant, name: "Alex")
    @manager = create(:person, tenant: @tenant, name: "Morgan")
    create(:tenant_user, tenant: @tenant, user: @assessee_user, person: @assessee, role: :member)
    create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
    @assessee.update!(manager: @manager)

    @framework_id = SecureRandom.uuid_v7
    @cap_stable = SecureRandom.uuid_v7
    @handler.assign_to_framework(@assessee.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    @assignment_id = PersonFrameworkAssignment
      .find_by(person_id: @assessee.id, framework_id: @framework_id).id
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def post!(author:, parent_id: nil, evidence_id: nil, body: "Worth discussing", id: SecureRandom.uuid_v7)
    @handler.post_comment(@assessee.id, @framework_id, id,
      commentable_type: evidence_id ? "evidence_link" : "assessment_cell",
      body: body, author_id: author.id,
      capability_stable_id: @cap_stable, level_ordinal: 2,
      evidence_id: evidence_id, parent_id: parent_id)
    id
  end

  context "assessee comments" do
    should "notify the manager side and not the assessee" do
      perform_enqueued_jobs { post!(author: @assessee, body: "I think this is now consistent") }

      assert_empty @assessee_user.notifications.reload
      notifications = @manager_user.notifications.reload
      assert_equal 1, notifications.size
      assert_equal "Alex commented on their assessment", notifications.first.inbox_title
      assert_equal "L2 — “I think this is now consistent”", notifications.first.inbox_body
      assert_equal "/assessments/#{@assignment_id}?capability=#{@cap_stable}&level_ordinal=2",
        notifications.first.inbox_url
    end

    should "notify an active rating delegate alongside the manager" do
      delegate_user = create(:user)
      delegate = create(:person, tenant: @tenant, name: "Devon")
      create(:tenant_user, tenant: @tenant, user: delegate_user, person: delegate, role: :member)
      @handler.delegate_manager_rating(@assessee.id, @framework_id, delegate.id, granted_by_id: @manager.id)

      perform_enqueued_jobs { post!(author: @assessee) }

      assert_equal 1, @manager_user.notifications.reload.size
      assert_equal 1, delegate_user.notifications.reload.size
      assert_equal "Alex commented on their assessment",
        delegate_user.notifications.first.inbox_title
    end

    should "prefer the recorded reporting manager over the live org chart" do
      recorded_user = create(:user)
      recorded = create(:person, tenant: @tenant, name: "Riley")
      create(:tenant_user, tenant: @tenant, user: recorded_user, person: recorded, role: :member)
      @handler.record_reporting_manager(@assessee.id, @framework_id, recorded.id, source: "hris")

      perform_enqueued_jobs { post!(author: @assessee) }

      assert_equal 1, recorded_user.notifications.reload.size
      assert_empty @manager_user.notifications.reload
    end
  end

  context "someone else comments" do
    should "notify the assessee and not the author" do
      perform_enqueued_jobs { post!(author: @manager) }

      assert_empty @manager_user.notifications.reload
      notifications = @assessee_user.notifications.reload
      assert_equal 1, notifications.size
      assert_equal "Morgan commented on your assessment", notifications.first.inbox_title
    end
  end

  context "replies" do
    should "notify the parent author with the reply notification only" do
      parent_id = post!(author: @manager, body: "Can you add an example?")
      perform_enqueued_jobs { post!(author: @assessee, parent_id: parent_id, body: "Added one") }

      # Manager matches both the reply rule and the manager-side rule — the
      # more specific reply notification wins, exactly once.
      notifications = @manager_user.notifications.reload
      assert_equal 1, notifications.size
      assert_equal "Alex replied to your comment", notifications.first.inbox_title
      assert_equal "L2 — “Added one”", notifications.first.inbox_body
    end

    should "notify the assessee with the reply notification when replying to them" do
      parent_id = nil
      perform_enqueued_jobs { parent_id = post!(author: @assessee, body: "Self note") }
      perform_enqueued_jobs { post!(author: @manager, parent_id: parent_id, body: "Agreed") }

      titles = @assessee_user.notifications.reload.map(&:inbox_title)
      assert_equal [ "Morgan replied to your comment" ], titles
    end
  end

  context "evidence-linkage threads" do
    should "name whose feedback is discussed in the context line" do
      peer = create(:person, tenant: @tenant, name: "Jordan")
      evidence_id = SecureRandom.uuid_v7
      @handler.record_evidence(@assessee.id, @framework_id, evidence_id,
        capability_stable_id: @cap_stable, level_ordinal: 2, source: "peer",
        evidence_type: "peer_feedback", content: "Paired on the incident",
        author_id: peer.id, valence: "demonstrated")

      perform_enqueued_jobs { post!(author: @manager, evidence_id: evidence_id, body: "Strong signal") }

      notification = @assessee_user.notifications.reload
        .find { |n| n.inbox_title == "Morgan commented on your assessment" }
      assert_not_nil notification
      assert_equal "Jordan's feedback · L2 — “Strong signal”", notification.inbox_body
    end
  end

  should "provision a user for a manager who has never logged in" do
    newcomer = create(:person, tenant: @tenant, name: "Newcomer", email: "new-manager@example.com")
    @assessee.update!(manager: newcomer)
    assert_nil newcomer.user, "precondition: no linked user"

    perform_enqueued_jobs { post!(author: @assessee) }

    user = newcomer.reload.user
    assert_not_nil user, "a user should have been provisioned to receive the notification"
    assert_equal 1, user.notifications.reload.size
  end
end
