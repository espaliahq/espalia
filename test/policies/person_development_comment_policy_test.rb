# frozen_string_literal: true

require "test_helper"

class PersonDevelopmentCommentPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @ceo = create(:person, tenant: @tenant, name: "CEO")
      @manager = create(:person, tenant: @tenant, name: "Manager", manager: @ceo)
      @assessee = create(:person, tenant: @tenant, name: "Assessee", manager: @manager)
      @peer = create(:person, tenant: @tenant, name: "Peer")

      @framework = create(:framework_state, name: "Test")
      @assignment = create(:person_framework_assignment,
        tenant: @tenant, person_id: @assessee.id, framework_id: @framework.framework_id)
    end
  end

  context "as the assessee" do
    setup { @ctx = ctx_for(@assessee) }

    should "allow index, show, create" do
      assert policy(@assignment).index?
      assert policy(@assignment).show?
      assert policy(@assignment).create?
    end

    should "allow update and destroy on own comment" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @assessee)
        assert policy(c).update?
        assert policy(c).destroy?
      end
    end

    should "deny update on someone else's comment" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @manager)
        assert_not policy(c).update?
      end
    end

    should "deny destroy on someone else's comment (non-admin)" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @manager)
        assert_not policy(c).destroy?
      end
    end
  end

  context "as the direct manager" do
    setup { @ctx = ctx_for(@manager) }

    should "allow show and create" do
      assert policy(@assignment).show?
      assert policy(@assignment).create?
    end
  end

  context "as a peer (tenant member but not in the chain)" do
    setup { @ctx = ctx_for(@peer) }

    should "deny viewing the assessment" do
      assert_not policy(@assignment).show?
    end

    should "deny creating — only assessment viewers may comment" do
      assert_not policy(@assignment).create?
    end

    should "deny update of others' comments" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @assessee)
        assert_not policy(c).update?
      end
    end

    # A peer who once authored a comment (e.g. before they were dropped
    # from the assessee's chain) keeps edit on their own words. The
    # commenting RIGHT requires assessment visibility, but the comment
    # itself, once written, belongs to its author.
    should "allow update of own comment" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @peer)
        assert policy(c).update?
      end
    end
  end

  context "as an active rating delegate (not in the chain)" do
    setup do
      @ctx = ctx_for(@peer)
      ActsAsTenant.with_tenant(@tenant) do
        create(:manager_assessment_delegation, tenant: @tenant, person_id: @assessee.id,
          framework_id: @framework.framework_id, delegate_person_id: @peer.id,
          granted_by_id: @manager.id)
      end
    end

    should "allow viewing and commenting on the assessment" do
      assert policy(@assignment).index?
      assert policy(@assignment).show?
      assert policy(@assignment).create?
    end

    should "deny once the delegation has expired" do
      ActsAsTenant.with_tenant(@tenant) do
        ManagerAssessmentDelegation.where(delegate_person_id: @peer.id)
          .update_all(expires_at: 1.day.ago)
      end
      assert_not policy(@assignment).create?
    end
  end

  context "as a tenant admin" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @admin_person = create(:person, tenant: @tenant, name: "Admin")
        user = create(:user)
        tu = create(:tenant_user, tenant: @tenant, user: user, person: @admin_person,
                                  role: :admin)
        @ctx = AuthorizationContext.new(user: user, tenant_user: tu, person: @admin_person)
      end
    end

    should "allow destroy on others' comments (moderation)" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @assessee)
        assert policy(c).destroy?
      end
    end

    should "deny update on others' comments (no admin edit override)" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @assessee)
        assert_not policy(c).update?
      end
    end
  end

  context "deleted comments" do
    setup { @ctx = ctx_for(@assessee) }

    should "deny update once deleted" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @assessee, status: "deleted")
        assert_not policy(c).update?
      end
    end

    should "deny destroy once deleted (no redundant deletes)" do
      ActsAsTenant.with_tenant(@tenant) do
        c = create(:person_development_comment, tenant: @tenant,
          person_id: @assessee.id, author: @assessee, status: "deleted")
        assert_not policy(c).destroy?
      end
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
    PersonDevelopmentCommentPolicy.new(@ctx, record)
  end
end
