# frozen_string_literal: true

require "test_helper"

class Frameworks::CapabilityArchivesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @survivor_stable = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Legacy Systems")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @survivor_stable, cat_id, "Platform Eng")
      handler.publish_version(@framework_id, "seed")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  def post_archive(user, archive)
    sign_in user
    post framework_capability_archives_path(framework_id: @framework_id), params: { archive: archive }
  end

  context "POST create" do
    should "archive with an evolved mapping, auto-open a draft, and record the mapping" do
      post_archive(@admin_user,
        { capability_id: @cap_id, reason: "Retired", mapping_type: "evolved", to_stable_id: @survivor_stable })

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Archived/, flash[:notice])
      assert framework.draft_in_progress

      mapping = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::MigrationMapping.find_by(framework_id: @framework_id, to_stable_id: @survivor_stable)
      end
      assert_not_nil mapping
      assert_equal "evolved", mapping.mapping_type
    end

    should "archive with no survivor for an archived mapping" do
      post_archive(@admin_user, { capability_id: @cap_id, reason: "Retired", mapping_type: "archived" })

      assert_redirected_to edit_framework_path(@framework_id)
      mapping = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::MigrationMapping.find_by(framework_id: @framework_id, mapping_type: "archived")
      end
      assert_not_nil mapping
      assert_nil mapping.to_stable_id
    end

    should "redirect a plain member (not authorized) and not open a draft" do
      post_archive(@member_user, { capability_id: @cap_id, reason: "x", mapping_type: "archived" })

      assert_redirected_to root_path
      assert_not framework.draft_in_progress
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
