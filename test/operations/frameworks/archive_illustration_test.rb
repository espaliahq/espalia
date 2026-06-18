# frozen_string_literal: true

require "test_helper"

# Illustration removal mirrors capability archiving: editing + approval rights
# removes directly (RoleIllustrationRemoved, applied live — illustrations carry
# no ratings); suggesting mode, or no approval authority, proposes it instead.
class Operations::Frameworks::ArchiveIllustrationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @collab_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      @collab_person = create(:person, tenant: @tenant)
      @collab_tu = create(:tenant_user, tenant: @tenant, user: @collab_user, role: :member, person: @collab_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7
      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      h.add_role_family(@framework_id, rfid, "Engineering")
      h.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      h.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7
      h.add_capability_category(@framework_id, cat_id, "Thinking")
      h.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      h.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks questions")
      h.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7, eid, rid, 1, "Seeks guidance")
      h.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator", added_by: @collab_person.id.to_s)
      h.publish_version(@framework_id, "seed") # publish so the illustration lands in the read model
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @collab_ctx = AuthorizationContext.new(user: @collab_user, tenant_user: @collab_tu, person: @collab_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def illustration
    FrameworkState::RoleIllustration.find_by(illustration_id: @ill_id)
  end

  def pending_archive_suggestions
    FrameworkState::SuggestedEdit.where(framework_id: @framework_id, kind: "delete",
                                        target_entity_id: @ill_id, status: "pending")
  end

  context "editing mode + approval authority" do
    should "remove the illustration directly" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ArchiveIllustration.call(
          context: @admin_ctx, params: { framework_id: @framework_id, illustration_id: @ill_id }
        )
        assert_equal true, result[:archived]
        assert_nil illustration, "the illustration should be removed live"
        assert_equal 0, pending_archive_suggestions.count
      end
    end
  end

  context "suggesting mode (authority-holder)" do
    should "propose the removal instead of applying it" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ArchiveIllustration.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, illustration_id: @ill_id, mode: "suggesting" }
        )
        assert_equal false, result[:archived]
        assert_not_nil illustration, "the illustration stays until the proposal is approved"
        assert_equal 1, pending_archive_suggestions.count
      end
    end
  end

  context "collaborator without approval authority (editing mode)" do
    should "propose the removal" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ArchiveIllustration.call(
          context: @collab_ctx, params: { framework_id: @framework_id, illustration_id: @ill_id, mode: "editing" }
        )
        assert_equal false, result[:archived]
        assert_equal 1, pending_archive_suggestions.count
        assert_not_nil illustration
      end
    end
  end

  context "as a plain tenant member (no suggest rights)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ArchiveIllustration.call(
            context: @member_ctx, params: { framework_id: @framework_id, illustration_id: @ill_id }
          )
        end
      end
    end
  end
end
