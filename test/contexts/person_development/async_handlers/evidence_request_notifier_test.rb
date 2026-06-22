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

  should "notify the requestee when evidence is requested, deep-linking to the request" do
    request_id = nil
    perform_enqueued_jobs { request_id = request! }

    notifications = @peer_user.notifications.reload
    assert_equal 1, notifications.size
    # Assessee asked about their own assessment — no redundant "regarding".
    assert_equal "Alex asked you for feedback", notifications.first.inbox_title
    assert_match "The request is for behavioural evidence", notifications.first.inbox_body
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

  should "notify the requester when the request is responded to" do
    id = request!
    evidence_id = SecureRandom.uuid_v7
    @handler.record_evidence(@assessee.id, @framework_id, evidence_id,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, source: "peer",
      evidence_type: "peer_feedback", content: "Paired on the incident", author_id: @peer.id)
    perform_enqueued_jobs do
      @handler.respond_to_evidence_request(@assessee.id, @framework_id, id,
        evidence_id: evidence_id, responded_by_id: @peer.id)
    end

    titles = @assessee_user.notifications.reload.map(&:inbox_title)
    assert_includes titles, "Jordan answered your evidence request"
  end

  should "notify the requester when the request is declined" do
    id = request!
    perform_enqueued_jobs do
      @handler.decline_evidence_request(@assessee.id, @framework_id, id, declined_by_id: @peer.id, reason: "No overlap")
    end

    titles = @assessee_user.notifications.reload.map(&:inbox_title)
    assert_includes titles, "Jordan declined your evidence request"
  end
end
