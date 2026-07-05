# frozen_string_literal: true

require "test_helper"

class Frameworks::CategoryReordersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_a = SecureRandom.uuid_v7
      @cat_b = SecureRandom.uuid_v7
      @cat_c = SecureRandom.uuid_v7
      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      h.add_capability_category(@framework_id, @cat_a, "Thinking")
      h.add_capability_category(@framework_id, @cat_b, "Delivery")
      h.add_capability_category(@framework_id, @cat_c, "Collaboration")
      h.publish_version(@framework_id, "seed")
    end
  end

  def ordered_ids
    ActsAsTenant.with_tenant(@tenant) do
      FrameworkState::CapabilityCategory
        .where(framework_id: @framework_id, status: "active")
        .order(:ordinal, :id).pluck(:category_id)
    end
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  context "POST create as admin" do
    should "move a category before its visible neighbour" do
      sign_in @admin_user
      post framework_category_reorders_path(framework_id: @framework_id),
           params: { reorder: { category_id: @cat_c, target_id: @cat_a, placement: "before" } },
           as: :json

      assert_response :no_content
      assert_equal [ @cat_c, @cat_a, @cat_b ], ordered_ids
    end

    should "answer 422 for a target outside the framework" do
      sign_in @admin_user
      post framework_category_reorders_path(framework_id: @framework_id),
           params: { reorder: { category_id: @cat_a, target_id: SecureRandom.uuid_v7, placement: "after" } },
           as: :json

      assert_response :unprocessable_content
      assert_equal [ @cat_a, @cat_b, @cat_c ], ordered_ids
    end
  end

  context "POST create as non-admin member" do
    should "deny the reorder and leave the order untouched" do
      sign_in @member_user
      post framework_category_reorders_path(framework_id: @framework_id),
           params: { reorder: { category_id: @cat_c, target_id: @cat_a, placement: "before" } },
           as: :json

      assert_response :redirect
      assert_equal [ @cat_a, @cat_b, @cat_c ], ordered_ids
    end
  end
end
