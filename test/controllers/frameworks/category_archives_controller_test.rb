# frozen_string_literal: true

require "test_helper"

class Frameworks::CategoryArchivesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @empty_cat = SecureRandom.uuid_v7
      @full_cat = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @empty_cat, "Empty")
      handler.add_capability_category(@framework_id, @full_cat, "Full")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @full_cat, "Platform Eng")
      handler.publish_version(@framework_id, "seed")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  def post_archive(user, archive)
    sign_in user
    post framework_category_archives_path(framework_id: @framework_id), params: { archive: archive }
  end

  context "POST create" do
    should "archive an empty category and auto-open a draft" do
      post_archive(@admin_user, { category_id: @empty_cat, reason: "Retired" })

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Archived/, flash[:notice])
      assert framework.draft_in_progress
    end

    should "surface the aggregate error when the category still holds capabilities" do
      post_archive(@admin_user, { category_id: @full_cat, reason: "Retired" })

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/active capability/i, flash[:alert])
      assert_not framework.draft_in_progress
    end

    should "redirect a plain member (not authorized) and not open a draft" do
      post_archive(@member_user, { category_id: @empty_cat, reason: "x" })

      assert_redirected_to root_path
      assert_not framework.draft_in_progress
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
