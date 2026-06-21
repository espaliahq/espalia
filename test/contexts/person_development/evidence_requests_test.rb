# frozen_string_literal: true

require "test_helper"

# Exercises the evidence-request lifecycle end to end: command handler →
# aggregate → events → EvidenceRequests projection → EvidenceRequest read model.
class PersonDevelopment::EvidenceRequestsTest < ActiveSupport::TestCase
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

    should "reject requesting evidence from the assessee themselves" do
      error = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        request!(requestee: @assessee)
      end
      assert_match(/assessee/i, error.message)
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
end
