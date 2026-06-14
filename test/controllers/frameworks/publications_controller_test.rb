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
