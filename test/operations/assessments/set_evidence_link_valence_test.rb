# frozen_string_literal: true

require "test_helper"

# Behaviour checks for the link-revalence Operation:
# - reclassifies a link's valence and returns the item's full link set
# - no-op (still succeeds) when the valence is unchanged
# - EvidencePolicy#add_link? gates who may reclassify (peer denied)
# - unknown coordinate surfaces as ParameterError
class Operations::Assessments::SetEvidenceLinkValenceTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @author_user = create(:user)
    @peer_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, email: @author_user.email, name: "Author")
      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Peer")
      @author_tu = create(:tenant_user, tenant: @tenant, user: @author_user, person: @author, role: :member)
      @peer_tu = create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

      framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2, description: "exp")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@author.id, framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @author.id, framework_id: framework_id)

      @evidence_id = SecureRandom.uuid_v7
      handler.record_evidence(@author.id, framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author.id,
        valence: "demonstrated")
    end

    @author_ctx = AuthorizationContext.new(user: @author_user, tenant_user: @author_tu, person: @author)
    @peer_ctx = AuthorizationContext.new(user: @peer_user, tenant_user: @peer_tu, person: @peer)
  end

  def call_op(ctx:, **overrides)
    params = {
      assignment_id: @assignment.id, evidence_id: @evidence_id,
      capability_stable_id: @cap.stable_id, level_ordinal: 2, valence: "growth_area"
    }.merge(overrides)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::SetEvidenceLinkValence.call(context: ctx, params: params)
    end
  end

  should "reclassify the link and return the updated link set" do
    result = call_op(ctx: @author_ctx)

    assert_equal "growth_area", result[:valence]
    assert_equal [ { capability_stable_id: @cap.stable_id, level_ordinal: 2, valence: "growth_area" } ],
      result[:links]
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "growth_area", EvidenceLink.find_by(evidence_id: @evidence_id).valence
    end
  end

  should "succeed as a no-op when the valence is unchanged" do
    result = call_op(ctx: @author_ctx, valence: "demonstrated")
    assert_equal "demonstrated", result[:valence]
  end

  should "deny an unrelated peer" do
    assert_raises(Pundit::NotAuthorizedError) { call_op(ctx: @peer_ctx) }
  end

  should "surface an unknown coordinate as a ParameterError" do
    err = assert_raises(Operations::Base::ParameterError) do
      call_op(ctx: @author_ctx, capability_stable_id: SecureRandom.uuid_v7)
    end
    assert_match(/not linked to that coordinate/, err.message)
  end

  should "reject an out-of-list valence at the parameter layer" do
    assert_raises(Operations::Base::ParameterError) { call_op(ctx: @author_ctx, valence: "positive") }
  end
end
