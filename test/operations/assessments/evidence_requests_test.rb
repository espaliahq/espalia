# frozen_string_literal: true

require "test_helper"

# Behaviour checks for the evidence-request Operations (request / respond /
# decline / cancel / list) — the web + MCP surface for the request lifecycle.
class Operations::Assessments::EvidenceRequestsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user)
    @report_user  = create(:user)
    @peer_user    = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      @report  = create(:person, tenant: @tenant, manager_id: @manager.id, email: @report_user.email, name: "Rep")
      @peer    = create(:person, tenant: @tenant, email: @peer_user.email, name: "Peer")
      @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report_tu  = create(:tenant_user, tenant: @tenant, user: @report_user, person: @report, role: :member)
      @peer_tu    = create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

      framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises")

      PersonDevelopment::CommandHandler.new.assign_to_framework(@report.id, framework_id, role.role_id, level.level_id)
      @cycle_id = SecureRandom.uuid_v7
      cycles_handler = AssessmentCycles::CommandHandler.new
      cycles_handler.define_cycle(@cycle_id, framework_id, "Q1", "regular", 1,
        defined_by: @manager.id)
      cycles_handler.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)
      @framework_id = framework_id
      @assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end

    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
    @report_ctx  = AuthorizationContext.new(user: @report_user, tenant_user: @report_tu, person: @report)
    @peer_ctx    = AuthorizationContext.new(user: @peer_user, tenant_user: @peer_tu, person: @peer)
  end

  def request!(ctx: @report_ctx, **overrides)
    base = {
      assignment_id: @assignment.id, requestee_person_id: @peer.id,
      capability_stable_id: @cap.stable_id, level_ordinal: 2, message: "Help please"
    }
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::RequestEvidence.call(context: ctx, params: base.merge(overrides))
    end
  end

  context "request_evidence" do
    should "let the assessee ask a peer and project a pending request" do
      result = request!
      ActsAsTenant.with_tenant(@tenant) do
        req = EvidenceRequest.find(result[:request_id])
        assert_equal "pending", req.status
        assert_equal @peer.id, req.requestee_person_id
        assert_equal @report.id, req.requested_by_id
        assert_equal @cycle_id, req.cycle_id
      end
    end

    should "let the manager ask on the report's behalf" do
      assert request!(ctx: @manager_ctx)[:request_id].present?
    end

    should "deny an unrelated peer from requesting on someone else's assessment" do
      assert_raises(Pundit::NotAuthorizedError) { request!(ctx: @peer_ctx) }
    end

    should "reject requesting evidence from yourself" do
      # default ctx is the report, so requesting from @report is self-request
      assert_raises(Operations::Base::ParameterError) { request!(requestee_person_id: @report.id) }
    end

    should "let the manager request evidence from the assessee (the report)" do
      result = request!(ctx: @manager_ctx, requestee_person_id: @report.id)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal @report.id, EvidenceRequest.find(result[:request_id]).requestee_person_id
      end
    end
  end

  context "respond / decline / cancel" do
    setup { @request_id = request![:request_id] }

    should "let the requestee respond by recording peer evidence" do
      result = ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::RespondToEvidenceRequest.call(
          context: @peer_ctx,
          params: { request_id: @request_id, evidence_type: "peer_feedback", content: "Strong systems thinking.", valence: "demonstrated" }
        )
      end

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "responded", EvidenceRequest.find(@request_id).status
        item = EvidenceItem.find(result[:evidence_id])
        assert_equal "peer", item.source
        assert_equal @peer.id, item.author_id
        assert_equal @report.id, item.person_id
        assert_equal @cycle_id, item.cycle_id
      end
    end

    should "record the assessee's answer to their manager's request as self evidence" do
      request_id = request!(ctx: @manager_ctx, requestee_person_id: @report.id)[:request_id]

      result = ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::RespondToEvidenceRequest.call(
          context: @report_ctx,
          params: { request_id: request_id, evidence_type: "observation", content: "My reflection.", valence: "demonstrated" }
        )
      end

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(result[:evidence_id])
        assert_equal "self", item.source
        assert_equal "self", item.feedback_direction
      end
    end

    should "attribute a late response to the request cycle after it closes" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycles::CommandHandler.new.close_cycle(@cycle_id)
        assert_equal "concluded",
          AssessmentCycleEnrollment.find_by(cycle_id: @cycle_id, person_id: @report.id).status
      end

      result = ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::RespondToEvidenceRequest.call(
          context: @peer_ctx,
          params: { request_id: @request_id, evidence_type: "peer_feedback",
                    content: "Delivered after close.", valence: "demonstrated" }
        )
      end

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal @cycle_id, EvidenceItem.find(result[:evidence_id]).cycle_id
      end
    end

    should "deny a non-requestee from responding" do
      assert_raises(Pundit::NotAuthorizedError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Assessments::RespondToEvidenceRequest.call(
            context: @manager_ctx,
            params: { request_id: @request_id, evidence_type: "peer_feedback", content: "x", valence: "demonstrated" }
          )
        end
      end
    end

    # Regression: an unknown external_reference key (e.g. `title`) used to
    # raise ActiveModel::UnknownAttributeError → -32603 at the MCP boundary.
    should "reject an external_reference with an unknown field as a ParameterError" do
      err = assert_raises(Operations::Base::ParameterError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Assessments::RespondToEvidenceRequest.call(
            context: @peer_ctx,
            params: { request_id: @request_id, evidence_type: "peer_feedback", content: "x", valence: "demonstrated",
                      external_reference: { url: "https://x.test", title: "My link" } }
          )
        end
      end
      assert_match(/unknown field/, err.message)
      assert_match(/title/, err.message)
    end

    should "let the requestee decline with a reason" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::DeclineEvidenceRequest.call(
          context: @peer_ctx, params: { request_id: @request_id, reason: "Didn't work together" }
        )
        req = EvidenceRequest.find(@request_id)
        assert_equal "declined", req.status
        assert_equal "Didn't work together", req.decline_reason
      end
    end

    should "let the requester cancel" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::CancelEvidenceRequest.call(context: @report_ctx, params: { request_id: @request_id })
        assert_equal "cancelled", EvidenceRequest.find(@request_id).status
      end
    end
  end

  context "evidence_requests_list" do
    should "split incoming and outgoing by the caller" do
      request!
      incoming = ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::EvidenceRequestsList.call(context: @peer_ctx, params: {})
      end
      outgoing = ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::EvidenceRequestsList.call(context: @report_ctx, params: {})
      end

      assert_equal 1, incoming[:incoming].size
      assert_empty incoming[:outgoing]
      assert_equal 1, outgoing[:outgoing].size
      assert_empty outgoing[:incoming]
    end

    should "surface due date and reminder state" do
      due = 5.days.from_now
      result = request!(due_at: due.iso8601)
      ActsAsTenant.with_tenant(@tenant) do
        req = EvidenceRequest.find(result[:request_id])
        PersonDevelopment::CommandHandler.new.remind_evidence_request(
          req.person_id, req.framework_id, req.id, kind: "no_response"
        )

        row = Operations::Assessments::EvidenceRequestsList
          .call(context: @report_ctx, params: {})[:outgoing].first
        assert_in_delta due.to_i, Time.zone.parse(row[:due_at]).to_i, 1
        assert_not_nil row[:last_reminded_at]
      end
    end
  end

  # Backdate a request so the NUDGE_GAP timing gate opens (the gate reads the
  # read model, so a direct column update is sufficient for these tests).
  def age_request!(requested_at)
    ActsAsTenant.with_tenant(@tenant) do
      EvidenceRequest.find(@request_id).update_column(:requested_at, requested_at)
    end
  end

  context "nudge_evidence_request" do
    setup do
      @request_id = request!()[:request_id]
    end

    should "let the requester nudge once the gap has passed, attributing them" do
      age_request!(3.days.ago)
      result = ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::NudgeEvidenceRequest.call(context: @report_ctx, params: { request_id: @request_id })
      end

      assert_equal "pending", result[:status]
      assert_not_nil result[:last_reminded_at]
      ActsAsTenant.with_tenant(@tenant) do
        entry = EvidenceRequest.find(@request_id).reminder_history.sole
        assert_equal "manual", entry["kind"]
        assert_equal @report.id, entry["by_id"]
      end
    end

    should "reject a nudge within the gap" do
      err = assert_raises(Operations::Base::ParameterError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Assessments::NudgeEvidenceRequest.call(context: @report_ctx, params: { request_id: @request_id })
        end
      end
      assert_match(/nudge again 2 days/i, err.message)
    end

    should "deny anyone but the requester or an admin" do
      age_request!(3.days.ago)
      assert_raises(Pundit::NotAuthorizedError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Assessments::NudgeEvidenceRequest.call(context: @peer_ctx, params: { request_id: @request_id })
        end
      end
    end

    should "reject nudging a resolved request" do
      age_request!(3.days.ago)
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::CancelEvidenceRequest.call(context: @report_ctx, params: { request_id: @request_id })
        assert_raises(Operations::Base::ParameterError) do
          Operations::Assessments::NudgeEvidenceRequest.call(context: @report_ctx, params: { request_id: @request_id })
        end
      end
    end
  end
end
