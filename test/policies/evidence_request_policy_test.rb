# frozen_string_literal: true

require "test_helper"

class EvidenceRequestPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7

    @manager = create(:person, tenant: @tenant, name: "Mgr")
    @report  = create(:person, tenant: @tenant, manager_id: @manager.id, name: "Rep")
    @peer    = create(:person, tenant: @tenant, name: "Peer")
    @admin   = create(:person, tenant: @tenant, name: "Admin")
    @admin_tu = create(:tenant_user, tenant: @tenant, user: create(:user), person: @admin, role: :admin)

    @assignment = PersonFrameworkAssignment.create!(
      tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
      role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7
    )
    @request = EvidenceRequest.create!(
      id: SecureRandom.uuid_v7, tenant: @tenant, person_id: @report.id, framework_id: @framework_id,
      requested_by_id: @report.id, requestee_person_id: @peer.id,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2,
      status: "pending", requested_at: Time.current
    )
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def ctx(person, tenant_user: nil)
    AuthorizationContext.new(user: tenant_user&.user, tenant_user: tenant_user, person: person)
  end

  context "request?" do
    should "permit the assessee and their manager chain" do
      assert EvidenceRequestPolicy.new(ctx(@report), @assignment).request?
      assert EvidenceRequestPolicy.new(ctx(@manager), @assignment).request?
    end

    should "deny an unrelated peer" do
      assert_not EvidenceRequestPolicy.new(ctx(@peer), @assignment).request?
    end

    should "permit a tenant admin" do
      assert EvidenceRequestPolicy.new(ctx(@admin, tenant_user: @admin_tu), @assignment).request?
    end
  end

  context "respond? / decline?" do
    should "permit only the requestee" do
      assert EvidenceRequestPolicy.new(ctx(@peer), @request).respond?
      assert EvidenceRequestPolicy.new(ctx(@peer), @request).decline?
      assert_not EvidenceRequestPolicy.new(ctx(@report), @request).respond?
      assert_not EvidenceRequestPolicy.new(ctx(@manager), @request).decline?
    end
  end

  context "cancel?" do
    should "permit the requester and a tenant admin, deny the requestee" do
      assert EvidenceRequestPolicy.new(ctx(@report), @request).cancel?
      assert EvidenceRequestPolicy.new(ctx(@admin, tenant_user: @admin_tu), @request).cancel?
      assert_not EvidenceRequestPolicy.new(ctx(@peer), @request).cancel?
    end
  end
end
