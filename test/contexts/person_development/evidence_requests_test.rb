# frozen_string_literal: true

require "test_helper"
require_relative "../../support/projection_replay"

# Exercises the evidence-request lifecycle end to end: command handler →
# aggregate → events → EvidenceRequests projection → EvidenceRequest read model.
class PersonDevelopment::EvidenceRequestsTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @assessee = create(:person, tenant: @tenant)
    @requestee = create(:person, tenant: @tenant)
    @framework_id = SecureRandom.uuid_v7
    @cap = SecureRandom.uuid_v7
    @handler.assign_to_framework(@assessee.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def request!(request_id = SecureRandom.uuid_v7, requestee: @requestee, level: 3)
    @handler.request_evidence(@assessee.id, @framework_id, request_id,
      requested_by_id: @assessee.id, requestee_person_id: requestee.id,
      capability_stable_id: @cap, level_ordinal: level, message: "Please help")
    request_id
  end

  context "request_evidence" do
    should "project a pending request anchored to the cell" do
      id = request!
      req = EvidenceRequest.find(id)

      assert_equal "pending", req.status
      assert_equal @requestee.id, req.requestee_person_id
      assert_equal @assessee.id, req.requested_by_id
      assert_equal @cap, req.capability_stable_id
      assert_equal 3, req.level_ordinal
      assert_equal "Please help", req.message
    end

    should "reject requesting evidence from yourself" do
      error = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        request!(requestee: @assessee) # requested_by is the assessee too
      end
      assert_match(/yourself/i, error.message)
    end

    should "allow someone else to request evidence from the assessee" do
      id = SecureRandom.uuid_v7
      @handler.request_evidence(@assessee.id, @framework_id, id,
        requested_by_id: @requestee.id, requestee_person_id: @assessee.id,
        capability_stable_id: @cap, level_ordinal: 3, message: "Add more please")
      assert_equal @assessee.id, EvidenceRequest.find(id).requestee_person_id
    end

    should "reject a duplicate request id" do
      id = request!
      assert_raises(PersonDevelopment::Aggregate::CommandError) { request!(id) }
    end
  end

  context "resolving a request" do
    should "mark it responded and link the evidence" do
      id = request!
      evidence_id = SecureRandom.uuid_v7
      @handler.record_evidence(@assessee.id, @framework_id, evidence_id,
        capability_stable_id: @cap, level_ordinal: 3, source: "peer",
        evidence_type: "peer_feedback", content: "Helped ship the migration", author_id: @requestee.id)
      @handler.respond_to_evidence_request(@assessee.id, @framework_id, id,
        evidence_id: evidence_id, responded_by_id: @requestee.id)

      req = EvidenceRequest.find(id)
      assert_equal "responded", req.status
      assert_equal evidence_id, req.evidence_id
    end

    should "reject responding with an evidence id that doesn't exist" do
      id = request!
      error = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @handler.respond_to_evidence_request(@assessee.id, @framework_id, id,
          evidence_id: SecureRandom.uuid_v7, responded_by_id: @requestee.id)
      end
      assert_match(/evidence id/i, error.message)
    end

    should "mark it declined with a reason" do
      id = request!
      @handler.decline_evidence_request(@assessee.id, @framework_id, id,
        declined_by_id: @requestee.id, reason: "Didn't work together")

      req = EvidenceRequest.find(id)
      assert_equal "declined", req.status
      assert_equal "Didn't work together", req.decline_reason
    end

    should "mark it cancelled" do
      id = request!
      @handler.cancel_evidence_request(@assessee.id, @framework_id, id, cancelled_by_id: @assessee.id)
      assert_equal "cancelled", EvidenceRequest.find(id).status
    end

    should "reject acting on an already-resolved request" do
      id = request!
      @handler.cancel_evidence_request(@assessee.id, @framework_id, id, cancelled_by_id: @assessee.id)

      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @handler.decline_evidence_request(@assessee.id, @framework_id, id, declined_by_id: @requestee.id)
      end
    end
  end

  context "remind_evidence_request" do
    should "stamp the per-kind reminded-at column on the read model" do
      id = request!
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")

      req = EvidenceRequest.find(id)
      assert_not_nil req.no_response_reminded_at
      assert_nil req.due_soon_reminded_at
      assert_equal req.no_response_reminded_at, req.last_reminded_at
    end

    should "stamp due_soon independently of no_response" do
      id = request!
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "due_soon")

      req = EvidenceRequest.find(id)
      assert_not_nil req.due_soon_reminded_at
      assert_nil req.no_response_reminded_at
    end

    should "reject sending the same kind twice" do
      id = request!
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")

      error = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")
      end
      assert_match(/already sent/i, error.message)
    end

    should "allow the other kind after one was sent" do
      id = request!
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "due_soon")

      req = EvidenceRequest.find(id)
      assert_not_nil req.no_response_reminded_at
      assert_not_nil req.due_soon_reminded_at
    end

    should "reject an unknown kind" do
      id = request!
      error = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "overdue")
      end
      assert_match(/unknown reminder kind/i, error.message)
    end

    should "reject reminding a resolved request" do
      id = request!
      @handler.decline_evidence_request(@assessee.id, @framework_id, id, declined_by_id: @requestee.id)

      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")
      end
    end

    # The reason reminders are events, not job-written columns: a projection
    # rebuild must reproduce reminder state, or the next sweep re-nudges
    # everyone whose request is still pending.
    should "survive reset! + replay with identical read-model state" do
      id = request!
      @handler.remind_evidence_request(@assessee.id, @framework_id, id, kind: "no_response")

      before_snapshot = snapshot_read_models(PersonDevelopment::Projections::EvidenceRequests, @tenant)
      assert_not_nil before_snapshot[:evidence_requests].first["no_response_reminded_at"]

      PersonDevelopment::Projections::EvidenceRequests.reset!(tenant: @tenant)
      assert_equal 0, EvidenceRequest.count

      Projections::Replayer.replay(
        projection_class: PersonDevelopment::Projections::EvidenceRequests,
        tenant: @tenant
      )

      assert_equal before_snapshot, snapshot_read_models(PersonDevelopment::Projections::EvidenceRequests, @tenant)
    end
  end
end
