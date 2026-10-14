# frozen_string_literal: true

require "test_helper"

# Verifies evidence-request events fan out to notifications: the requestee is
# notified on request; the requester on response/decline.
class PersonDevelopment::AsyncHandlers::EvidenceRequestNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @assessee_user = create(:user)
    @peer_user = create(:user)
    @assessee = create(:person, tenant: @tenant, name: "Alex")
    @peer = create(:person, tenant: @tenant, name: "Jordan")
    create(:tenant_user, tenant: @tenant, user: @assessee_user, person: @assessee, role: :member)
    create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

    @framework_id = SecureRandom.uuid_v7
    @handler.assign_to_framework(@assessee.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def request!(id = SecureRandom.uuid_v7)
    @handler.request_evidence(@assessee.id, @framework_id, id,
      requested_by_id: @assessee.id, requestee_person_id: @peer.id,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, message: "Pairing notes?")
    id
  end

  should "provision a user and notify a requestee who has never logged in" do
    newcomer = create(:person, tenant: @tenant, name: "Newcomer", email: "newcomer@example.com")
    assert_nil newcomer.user, "precondition: no linked user"

    perform_enqueued_jobs do
      @handler.request_evidence(@assessee.id, @framework_id, SecureRandom.uuid_v7,
        requested_by_id: @assessee.id, requestee_person_id: newcomer.id,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2)
    end

    user = newcomer.reload.user
    assert_not_nil user, "a user should have been provisioned to receive the notification"
    assert_equal 1, user.notifications.reload.size
  end

  should "notify the requestee when evidence is requested, deep-linking to the request" do
    request_id = nil
    perform_enqueued_jobs { request_id = request! }

    notifications = @peer_user.notifications.reload
    assert_equal 1, notifications.size
    # Assessee asked about their own assessment — no redundant "regarding".
    assert_equal "Alex asked you for feedback", notifications.first.inbox_title
    assert_match "The request is for behavioural feedback", notifications.first.inbox_body
    assert_equal "/evidence#evidence-request-#{request_id}", notifications.first.inbox_url
  end

  should "name the assessee with 'regarding' when a manager asks on a report's behalf" do
    manager = create(:person, tenant: @tenant, name: "Morgan")
    create(:tenant_user, tenant: @tenant, user: create(:user), person: manager, role: :member)
    perform_enqueued_jobs do
      @handler.request_evidence(@assessee.id, @framework_id, SecureRandom.uuid_v7,
        requested_by_id: manager.id, requestee_person_id: @peer.id,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, message: "Pairing notes?")
    end
    assert_equal "Morgan asked you for feedback regarding Alex", @peer_user.notifications.reload.last.inbox_title
  end

  should "notify the requester with the response when the request is responded to" do
    id = request!
    evidence_id = SecureRandom.uuid_v7
    @handler.record_evidence(@assessee.id, @framework_id, evidence_id,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, source: "peer",
      evidence_type: "peer_feedback", content: "Paired on the incident", author_id: @peer.id, valence: "demonstrated")
    perform_enqueued_jobs do
      @handler.respond_to_evidence_request(@assessee.id, @framework_id, id,
        evidence_id: evidence_id, responded_by_id: @peer.id)
    end

    notification = @assessee_user.notifications.reload
      .find { |n| n.inbox_title == "Jordan answered your feedback request" }
    assert_not_nil notification
    assert_equal "“Paired on the incident”", notification.inbox_body
  end

  should "quote a Markdown response as the text a reader sees, not its syntax" do
    id = request!
    evidence_id = SecureRandom.uuid_v7
    @handler.record_evidence(@assessee.id, @framework_id, evidence_id,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, source: "peer",
      evidence_type: "peer_feedback", content: "**Led** the [incident review](https://example.com/ir)",
      author_id: @peer.id, valence: "demonstrated")
    perform_enqueued_jobs do
      @handler.respond_to_evidence_request(@assessee.id, @framework_id, id,
        evidence_id: evidence_id, responded_by_id: @peer.id)
    end

    body = @assessee_user.notifications.reload.max_by(&:created_at).inbox_body
    assert_equal "“Led the incident review”", body
  end

  should "truncate a long response in the notification body" do
    id = request!
    evidence_id = SecureRandom.uuid_v7
    @handler.record_evidence(@assessee.id, @framework_id, evidence_id,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, source: "peer",
      evidence_type: "peer_feedback", content: "detail " * 100, author_id: @peer.id, valence: "demonstrated")
    perform_enqueued_jobs do
      @handler.respond_to_evidence_request(@assessee.id, @framework_id, id,
        evidence_id: evidence_id, responded_by_id: @peer.id)
    end

    body = @assessee_user.notifications.reload.max_by(&:created_at).inbox_body
    assert_operator body.length, :<=, ApplicationNotifier::EXCERPT_LIMIT + 2 # + the quote marks
    assert_match(/…”\z/, body)
  end

  should "notify the requester with the reason when the request is declined" do
    id = request!
    perform_enqueued_jobs do
      @handler.decline_evidence_request(@assessee.id, @framework_id, id, declined_by_id: @peer.id, reason: "No overlap")
    end

    notification = @assessee_user.notifications.reload
      .find { |n| n.inbox_title == "Jordan declined your feedback request" }
    assert_not_nil notification
    assert_equal "“No overlap”", notification.inbox_body
  end

  should "notify a reasonless decline with an empty body" do
    id = request!
    perform_enqueued_jobs do
      @handler.decline_evidence_request(@assessee.id, @framework_id, id, declined_by_id: @peer.id)
    end

    notification = @assessee_user.notifications.reload
      .find { |n| n.inbox_title == "Jordan declined your feedback request" }
    assert_not_nil notification
    assert_nil notification.inbox_body
  end

  should "nudge the requestee on a no_response reminder" do
    id = request!
    perform_enqueued_jobs do
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")
    end

    notification = @peer_user.notifications.reload.max_by(&:created_at)
    assert_equal "Reminder: Alex is still waiting on your feedback", notification.inbox_title
    assert_match "The request is for behavioural feedback", notification.inbox_body
    assert_equal "/evidence#evidence-request-#{id}", notification.inbox_url
  end

  should "name the due date on a due_soon reminder" do
    id = SecureRandom.uuid_v7
    due = 2.days.from_now
    @handler.request_evidence(@assessee.id, @framework_id, id,
      requested_by_id: @assessee.id, requestee_person_id: @peer.id,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, due_at: due.iso8601)
    perform_enqueued_jobs do
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "due_soon")
    end

    notification = @peer_user.notifications.reload.max_by(&:created_at)
    assert_equal "Reminder: Alex's feedback request is due #{due.strftime('%a %-d %b')}",
      notification.inbox_title
  end

  should "name the nudger on a manual nudge" do
    id = request!
    perform_enqueued_jobs do
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "manual", nudged_by_id: @assessee.id)
    end

    notification = @peer_user.notifications.reload.max_by(&:created_at)
    assert_equal "Alex nudged you about their feedback request", notification.inbox_title
  end

  should "not nudge when the request was resolved before the job ran" do
    id = request!
    # Reminder event lands first, but the decline resolves the request before
    # the async notifier job performs — the nudge must be dropped.
    @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")
    @handler.decline_evidence_request(@assessee.id, @framework_id, id, declined_by_id: @peer.id)
    perform_enqueued_jobs

    titles = @peer_user.notifications.reload.map(&:inbox_title)
    assert_not titles.any? { |t| t.start_with?("Reminder:") }, "reminder should be dropped: #{titles}"
  end
end
