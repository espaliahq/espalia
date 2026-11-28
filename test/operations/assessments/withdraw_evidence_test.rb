# frozen_string_literal: true

require "test_helper"

# Covers withdrawing an evidence item over MCP: the soft-delete effect,
# author/admin authorisation, and the peer denial.
class Operations::Assessments::WithdrawEvidenceTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)
      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "X")
      @pd = PersonDevelopment::CommandHandler.new
      @pd.assign_to_framework(@person.id, @framework_id, @role.role_id,
        FrameworkState::Level.find_by(role_id: @role.role_id, ordinal: 2).level_id)
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first

      @evidence_id = SecureRandom.uuid_v7
      @pd.record_evidence(@person.id, @framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome",
        content: "Body", author_id: @person.id, valence: "demonstrated")
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(context: @context, **overrides)
    params = { assignment_id: @assignment.id, evidence_id: @evidence_id }.merge(overrides)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::WithdrawEvidence.call(context: context, params: params)
    end
  end

  should "withdraw the item and report its status" do
    result = call_op(reason: "wrong cell")
    assert_equal @evidence_id, result[:evidence_id]
    assert_equal "withdrawn", result[:status]
    assert result[:withdrawn_at].present?

    reloaded = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(@evidence_id) }
    assert reloaded.withdrawn?
  end

  should "permit a tenant admin to withdraw another person's evidence" do
    admin_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin_person = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
      tu = create(:tenant_user, tenant: @tenant, user: admin_user, person: admin_person, role: :admin)
      ctx = AuthorizationContext.new(user: admin_user, tenant_user: tu, person: admin_person)
      result = call_op(context: ctx)
      assert_equal "withdrawn", result[:status]
    end
  end

  should "deny a peer who is not author, manager, or admin" do
    other_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      other = create(:person, tenant: @tenant, email: other_user.email)
      tu = create(:tenant_user, tenant: @tenant, user: other_user, person: other, role: :member)
      ctx = AuthorizationContext.new(user: other_user, tenant_user: tu, person: other)
      assert_raises(Pundit::NotAuthorizedError) { call_op(context: ctx) }
    end
  end

  context "on a forgotten subject" do
    setup do
      @author_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        @author = create(:person, tenant: @tenant, email: @author_user.email, name: "Peer")
        author_tu = create(:tenant_user, tenant: @tenant, user: @author_user, person: @author, role: :member)
        @author_context = AuthorizationContext.new(user: @author_user, tenant_user: author_tu, person: @author)
        @peer_evidence_id = SecureRandom.uuid_v7
        @pd.record_evidence(@person.id, @framework_id, @peer_evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          source: "peer", evidence_type: "peer_feedback",
          content: "Calm on the call.", author_id: @author.id, valence: "demonstrated")
        @person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
      end
    end

    should "let the author withdraw it, storing no reason" do
      result = call_op(context: @author_context, evidence_id: @peer_evidence_id)

      assert_equal "withdrawn", result[:status]
      item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(@peer_evidence_id) }
      assert_equal @author.id, item.withdrawn_by_id
      assert_nil item.withdrawal_reason
    end

    should "take a blank reason as none" do
      assert_equal "withdrawn", call_op(context: @author_context, evidence_id: @peer_evidence_id, reason: " ")[:status]
    end

    should "refuse a reason and store nothing" do
      error = assert_raises(Operations::Base::ParameterError) do
        call_op(context: @author_context, evidence_id: @peer_evidence_id, reason: "wrong person")
      end

      assert_equal "feedback about a former member is withdrawn without a reason", error.message
      assert ActsAsTenant.with_tenant(@tenant) { !EvidenceItem.find(@peer_evidence_id).withdrawn? }
    end

    should "refuse a tenant admin who isn't the author" do
      admin_user = create(:user)
      ctx = ActsAsTenant.with_tenant(@tenant) do
        admin = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
        tu = create(:tenant_user, tenant: @tenant, user: admin_user, person: admin, role: :admin)
        AuthorizationContext.new(user: admin_user, tenant_user: tu, person: admin)
      end

      error = assert_raises(Operations::Base::ParameterError) { call_op(context: ctx, evidence_id: @peer_evidence_id) }

      assert_equal "only its author can withdraw feedback about a former member", error.message
      assert ActsAsTenant.with_tenant(@tenant) { !EvidenceItem.find(@peer_evidence_id).withdrawn? }
    end

    should "give a stranger the ordinary refusal first" do
      other_user = create(:user)
      ctx = ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email)
        tu = create(:tenant_user, tenant: @tenant, user: other_user, person: other, role: :member)
        AuthorizationContext.new(user: other_user, tenant_user: tu, person: other)
      end

      assert_raises(Pundit::NotAuthorizedError) { call_op(context: ctx, evidence_id: @peer_evidence_id, reason: "x") }
    end
  end

  should "keep the reason on a live subject's withdrawal" do
    call_op(reason: "wrong cell")
    assert_equal "wrong cell", ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(@evidence_id).withdrawal_reason }
  end
end
