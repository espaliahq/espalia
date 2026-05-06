# frozen_string_literal: true

require "test_helper"

class EvidencePolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @ceo = create(:person, tenant: @tenant, name: "CEO")
      @skip_level = create(:person, tenant: @tenant, name: "Skip", manager: @ceo)
      @manager = create(:person, tenant: @tenant, name: "Manager", manager: @skip_level)
      @assessee = create(:person, tenant: @tenant, name: "Assessee", manager: @manager)
      @peer = create(:person, tenant: @tenant, name: "Peer")

      @framework = create(:framework_state, name: "Test")
      @assignment = create(:person_framework_assignment,
        tenant: @tenant, person_id: @assessee.id, framework_id: @framework.framework_id)
    end
  end

  context "as the assessee" do
    setup { @ctx = ctx_for(@assessee) }

    should "allow show, index, create" do
      assert policy(@assignment).index?
      assert policy(@assignment).show?
      assert policy(@assignment).create?
    end

    should "allow relink of own evidence" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @assessee)
        assert policy(item).relink?
      end
    end

    should "deny withdraw of evidence authored by someone else" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @manager)
        assert_not policy(item).withdraw?
      end
    end
  end

  context "as the direct manager" do
    setup { @ctx = ctx_for(@manager) }

    should "allow viewing and creating" do
      assert policy(@assignment).show?
      assert policy(@assignment).create?
    end

    should "allow relinking even of evidence they didn't author" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @peer)
        assert policy(item).relink?
      end
    end
  end

  context "as the skip-level manager" do
    setup { @ctx = ctx_for(@skip_level) }

    should "allow viewing" do
      assert policy(@assignment).show?
    end

    should "allow creating" do
      assert policy(@assignment).create?
    end

    should "allow relinking evidence on the assessee" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @manager)
        assert policy(item).relink?
      end
    end
  end

  context "as a top-of-chain manager (CEO)" do
    setup { @ctx = ctx_for(@ceo) }

    should "still allow viewing and creating" do
      assert policy(@assignment).show?
      assert policy(@assignment).create?
    end
  end

  context "as the original author" do
    setup { @ctx = ctx_for(@manager) }

    should "allow withdraw of own evidence" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @manager)
        assert policy(item).withdraw?
      end
    end
  end

  context "as an unrelated peer" do
    setup { @ctx = ctx_for(@peer) }

    should "deny show on the assessment" do
      assert_not policy(@assignment).show?
    end

    should "still allow creating peer evidence" do
      # V1: any tenant member can record peer evidence on anyone.
      assert policy(@assignment).create?
    end

    should "deny withdraw of evidence they didn't author" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @manager)
        assert_not policy(item).withdraw?
      end
    end

    should "deny relink of evidence they didn't author on someone outside their chain" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @manager)
        assert_not policy(item).relink?
      end
    end
  end

  context "as a tenant admin (not in chain)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @admin_user = create(:user)
        @admin_person = create(:person, tenant: @tenant, name: "Admin")
        @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, person: @admin_person, role: :admin)
        @ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
      end
    end

    should "view, create, and withdraw any evidence" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant, person_id: @assessee.id, author: @manager)
        assert policy(@assignment).show?
        assert policy(@assignment).create?
        assert policy(item).withdraw?
      end
    end
  end

  context "with no person" do
    setup do
      user = create(:user)
      tu = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: user) }
      @ctx = AuthorizationContext.new(user: user, tenant_user: tu, person: nil)
    end

    should "deny everything" do
      assert_not policy(@assignment).show?
      assert_not policy(@assignment).create?
    end
  end

  private

  def ctx_for(target_person)
    ActsAsTenant.with_tenant(@tenant) do
      user = create(:user)
      tu = create(:tenant_user, tenant: @tenant, user: user, person: target_person)
      AuthorizationContext.new(user: user, tenant_user: tu, person: target_person)
    end
  end

  def policy(record)
    EvidencePolicy.new(@ctx, record)
  end
end
