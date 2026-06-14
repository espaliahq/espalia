# frozen_string_literal: true

require "test_helper"

class Frameworks::PublicationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      Frameworks::CommandHandler.new.create_framework(@framework_id, "Test Framework")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  context "GET /frameworks/:framework_id/publication/new (review)" do
    should "render the review page for an admin with nothing retiring" do
      sign_in @admin_user
      get new_framework_publication_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Publish v1"
      assert_includes response.body, "No capabilities are being retired"
    end

    should "list a retiring capability that still needs a mapping" do
      cap_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        cat_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, cat_id, "Thinking")
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Legacy Systems")
        handler.publish_version(@framework_id, "seed")            # v1, cap pre-draft
        handler.archive_capability(@framework_id, cap_id, reason: "x") # auto-opens v2, no mapping
      end

      sign_in @admin_user
      get new_framework_publication_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Legacy Systems"
      assert_includes response.body, "Needs a mapping"
    end

    should "redirect non-publisher members" do
      sign_in @member_user
      get new_framework_publication_path(framework_id: @framework_id)
      assert_redirected_to root_path
    end
  end

  context "POST /frameworks/:framework_id/publication" do
    should "publish the draft for a tenant admin and advance the version" do
      sign_in @admin_user
      post framework_publication_path(framework_id: @framework_id)

      assert_redirected_to edit_framework_path(@framework_id)
      assert_equal "Published v1.", flash[:notice]
      assert_equal 1, framework.current_published_version
      assert_not framework.draft_in_progress
    end

    should "redirect non-publisher members with an authorization alert" do
      sign_in @member_user
      post framework_publication_path(framework_id: @framework_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert framework.draft_in_progress
    end

    should "surface the aggregate error when there is no draft" do
      sign_in @admin_user
      post framework_publication_path(framework_id: @framework_id) # publishes v1, clears draft
      post framework_publication_path(framework_id: @framework_id) # no draft now

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/no draft/i, flash[:alert])
    end

    should "redirect unauthenticated users to sign in" do
      post framework_publication_path(framework_id: @framework_id)
      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
