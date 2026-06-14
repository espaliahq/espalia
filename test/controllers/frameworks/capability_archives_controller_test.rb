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

  context "GET new" do
    should "render the archive form for an edit-rights holder" do
      sign_in @admin_user
      get new_framework_capability_archive_path(@framework_id, @cap_id)

      assert_response :success
      assert_includes response.body, "Archive"
      assert_includes response.body, "Migration mapping"  # pre-draft cap needs a mapping
    end

    should "redirect a plain member (not authorized)" do
      sign_in @member_user
      get new_framework_capability_archive_path(@framework_id, @cap_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "POST create" do
    should "archive with an evolved mapping, auto-open a draft, and record the mapping" do
      sign_in @admin_user
      post framework_capability_archive_path(@framework_id, @cap_id),
           params: { archive: { reason: "Retired", mapping_type: "evolved", to_stable_id: @survivor_stable } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Archived/, flash[:notice])
      assert framework.draft_in_progress

      mapping = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::MigrationMapping.find_by(framework_id: @framework_id, to_stable_id: @survivor_stable)
      end
      assert_not_nil mapping
      assert_equal "evolved", mapping.mapping_type
    end

    should "redirect a plain member (not authorized)" do
      sign_in @member_user
      post framework_capability_archive_path(@framework_id, @cap_id),
           params: { archive: { reason: "x", mapping_type: "archived" } }

      assert_redirected_to root_path
      assert framework.draft_in_progress == false
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
