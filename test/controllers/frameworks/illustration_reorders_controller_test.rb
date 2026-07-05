# frozen_string_literal: true

require "test_helper"

class Frameworks::IllustrationReordersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @exp_id = SecureRandom.uuid_v7
      @ill_a = SecureRandom.uuid_v7
      @ill_b = SecureRandom.uuid_v7
      @ill_c = SecureRandom.uuid_v7
      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      h.add_role_family(@framework_id, rfid, "Engineering")
      h.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      h.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "E1", "E1")
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      h.add_capability_category(@framework_id, cat_id, "Thinking")
      h.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      h.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7, cap_id, 1, "Asks questions")
      h.add_role_illustration(@framework_id, @ill_a, SecureRandom.uuid_v7, @exp_id, @role_id, 1, "First")
      h.add_role_illustration(@framework_id, @ill_b, SecureRandom.uuid_v7, @exp_id, @role_id, 2, "Second")
      h.add_role_illustration(@framework_id, @ill_c, SecureRandom.uuid_v7, @exp_id, @role_id, 3, "Third")
      h.publish_version(@framework_id, "seed")
    end
  end

  def ordered_ids
    ActsAsTenant.with_tenant(@tenant) do
      FrameworkState::RoleIllustration
        .where(expectation_id: @exp_id, role_id: @role_id)
        .order(:ordinal, :id).pluck(:illustration_id)
    end
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  context "POST create as admin" do
    should "move an illustration before its previous neighbour" do
      sign_in @admin_user
      post framework_illustration_reorders_path(framework_id: @framework_id),
           params: { reorder: { illustration_id: @ill_c, target_id: @ill_b, placement: "before" } },
           as: :json

      assert_response :no_content
      assert_equal [ @ill_a, @ill_c, @ill_b ], ordered_ids
    end

    should "move an illustration after its next neighbour" do
      sign_in @admin_user
      post framework_illustration_reorders_path(framework_id: @framework_id),
           params: { reorder: { illustration_id: @ill_a, target_id: @ill_b, placement: "after" } },
           as: :json

      assert_response :no_content
      assert_equal [ @ill_b, @ill_a, @ill_c ], ordered_ids
    end

    should "answer 422 for a self-target move" do
      sign_in @admin_user
      post framework_illustration_reorders_path(framework_id: @framework_id),
           params: { reorder: { illustration_id: @ill_a, target_id: @ill_a, placement: "before" } },
           as: :json

      assert_response :unprocessable_content
      assert_equal [ @ill_a, @ill_b, @ill_c ], ordered_ids
    end

    should "answer 422 for a malformed placement" do
      sign_in @admin_user
      post framework_illustration_reorders_path(framework_id: @framework_id),
           params: { reorder: { illustration_id: @ill_a, target_id: @ill_b, placement: "sideways" } },
           as: :json

      assert_response :unprocessable_content
      assert_equal [ @ill_a, @ill_b, @ill_c ], ordered_ids
    end

    should "answer 422 for a stale target that is not in the list" do
      sign_in @admin_user
      post framework_illustration_reorders_path(framework_id: @framework_id),
           params: { reorder: { illustration_id: @ill_a, target_id: SecureRandom.uuid_v7, placement: "before" } },
           as: :json

      assert_response :unprocessable_content
      assert_equal [ @ill_a, @ill_b, @ill_c ], ordered_ids
    end
  end

  context "POST create as non-admin member" do
    should "deny the reorder and leave the order untouched" do
      sign_in @member_user
      post framework_illustration_reorders_path(framework_id: @framework_id),
           params: { reorder: { illustration_id: @ill_c, target_id: @ill_b, placement: "before" } },
           as: :json

      assert_response :redirect
      assert_equal [ @ill_a, @ill_b, @ill_c ], ordered_ids
    end
  end
end
