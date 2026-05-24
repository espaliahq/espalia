# frozen_string_literal: true

require "test_helper"

# Behaviour checks for the evidence-recording Operation:
# - happy path persists an EvidenceItem and returns the canonical fields
# - source is derived from the caller's relationship to the assessee
#   (self / manager / peer) — never trusted from input
# - "other" evidence_type requires custom_type_label upfront
# - external_reference URLs are validated before they hit the event stream
# - level_ordinal must exist for the assignment's role
# - non-members of the assessment get a Pundit denial
class Operations::Assessments::RecordEvidenceTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user)
    @report_user  = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      @report  = create(:person, tenant: @tenant, manager_id: @manager.id, email: @report_user.email, name: "Rep")
      @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report_tu  = create(:tenant_user, tenant: @tenant, user: @report_user, person: @report, role: :member)

      framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises")

      pd_handler = PersonDevelopment::CommandHandler.new
      cycles_handler = AssessmentCycles::CommandHandler.new
      pd_handler.assign_to_framework(@report.id, framework_id, role.role_id, level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycles_handler.define_cycle(@cycle_id, framework_id, "Q1", "regular", 1, defined_by: @manager.id)
      cycles_handler.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)

      @framework_id = framework_id
      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end

    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
    @report_ctx  = AuthorizationContext.new(user: @report_user, tenant_user: @report_tu,  person: @report)
  end

  def call_op(ctx:, **overrides)
    base = {
      assignment_id: @report_assignment.id,
      capability_stable_id: @cap.stable_id,
      level_ordinal: 2,
      evidence_type: "project_outcome",
      content: "Led the refactor of the payments pipeline."
    }
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::RecordEvidence.call(context: ctx, params: base.merge(overrides))
    end
  end

  context "happy path — assessee recording their own evidence" do
    should "persist an EvidenceItem with source 'self' and return the canonical fields" do
      result = call_op(ctx: @report_ctx)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(result[:evidence_id])
        assert_equal "self", item.source
        assert_equal "project_outcome", item.evidence_type
        assert_equal @report.id, item.person_id
        assert_equal @report.id, item.author_id
      end
      assert_equal @report.id, result[:person_id]
      assert_equal "self", result[:source]
      assert_equal @cap.stable_id, result[:capability_stable_id]
      assert_equal 2, result[:level_ordinal]
      assert result[:recorded_at].present?
    end
  end

  context "manager evidencing a direct report" do
    should "derive source = 'manager' (never trusted from input)" do
      result = call_op(ctx: @manager_ctx)
      assert_equal "manager", result[:source]
    end
  end

  context "peer evidence" do
    should "derive source = 'peer' when caller is neither assessee nor in manager chain" do
      peer_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        peer_person = create(:person, tenant: @tenant, email: peer_user.email, name: "Peer")
        peer_tu = create(:tenant_user, tenant: @tenant, user: peer_user, person: peer_person, role: :member)
        peer_ctx = AuthorizationContext.new(user: peer_user, tenant_user: peer_tu, person: peer_person)

        result = Operations::Assessments::RecordEvidence.call(
          context: peer_ctx,
          params: {
            assignment_id: @report_assignment.id,
            capability_stable_id: @cap.stable_id,
            level_ordinal: 2,
            evidence_type: "peer_feedback",
            content: "Pairs effectively across teams."
          }
        )
        assert_equal "peer", result[:source]
      end
    end
  end

  context "validation" do
    should "require custom_type_label when evidence_type is 'other'" do
      err = assert_raises(Operations::Base::ParameterError) do
        call_op(ctx: @report_ctx, evidence_type: "other", custom_type_label: nil)
      end
      assert_match(/custom_type_label/, err.message)
    end

    should "reject an external_reference with a non-http(s) URL" do
      err = assert_raises(Operations::Base::ParameterError) do
        call_op(ctx: @report_ctx,
          external_reference: { system: "jira", url: "javascript:alert(1)" })
      end
      assert_match(/invalid external_reference/, err.message)
    end

    should "reject a level_ordinal that doesn't exist on the assignment's role" do
      err = assert_raises(Operations::Base::ParameterError) do
        call_op(ctx: @report_ctx, level_ordinal: 99)
      end
      assert_match(/does not exist/, err.message)
    end

    should "reject an unknown evidence_type at the parameter layer" do
      assert_raises(Operations::Base::ParameterError) do
        call_op(ctx: @report_ctx, evidence_type: "telepathy")
      end
    end
  end

  context "policy" do
    should "deny callers without a linked Person" do
      stranger = create(:user)
      ctx = AuthorizationContext.new(user: stranger, tenant_user: nil, person: nil)
      assert_raises(Pundit::NotAuthorizedError) { call_op(ctx: ctx) }
    end
  end

  context "audit metadata" do
    should "stamp acting_via on the EvidenceRecorded event" do
      observed = nil
      handler = ->(e) { observed = e.metadata.to_h }

      Rails.configuration.event_store
        .within do
          AuditMetadata.with(acting_via: :mcp, client_application_id: "app-xyz") do
            call_op(ctx: @report_ctx)
          end
        end
        .subscribe(handler, to: [ PersonDevelopment::Events::EvidenceRecorded ])
        .call

      assert observed, "expected EvidenceRecorded event to be published"
      assert_equal "mcp",     observed[:acting_via]
      assert_equal "app-xyz", observed[:client_application_id]
    end
  end
end
