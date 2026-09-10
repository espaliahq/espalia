# frozen_string_literal: true

require "test_helper"

class Frameworks::CapabilityReordersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_a = SecureRandom.uuid_v7
      @cap_b = SecureRandom.uuid_v7
      @cap_c = SecureRandom.uuid_v7
      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      h.add_capability_category(@framework_id, @cat_id, "Thinking")
      h.add_capability(@framework_id, @cap_a, SecureRandom.uuid_v7, @cat_id, "Alpha")
      h.add_capability(@framework_id, @cap_b, SecureRandom.uuid_v7, @cat_id, "Beta")
      h.add_capability(@framework_id, @cap_c, SecureRandom.uuid_v7, @cat_id, "Gamma")
      h.publish_version(@framework_id, "seed")
    end
  end

  def graph_order
    Frameworks::ExplorerGraph.load(@framework_id)
      .capability_categories.find { |c| c.category_id == @cat_id }
      .capabilities.map(&:capability_id)
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  context "POST create as admin" do
    should "move a capability before its visible neighbour" do
      sign_in @admin_user
      post framework_capability_reorders_path(framework_id: @framework_id),
           params: { reorder: { capability_id: @cap_c, target_id: @cap_a, placement: "before" } },
           as: :json

      # Toast only — `reorder-move` repositions the rows in place rather than
      # re-fetching the whole matrix frame (#381).
      assert_write_toast(/^.*Moved/)
      assert_no_navigation
      assert_equal [ @cap_c, @cap_a, @cap_b ], graph_order
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal [ @cap_c, @cap_a, @cap_b ],
                     FrameworkState::Capability.where(category_id: @cat_id)
                       .order(:ordinal, :id).pluck(:capability_id)
      end
    end

    should "answer 422 for a target outside the category" do
      sign_in @admin_user
      post framework_capability_reorders_path(framework_id: @framework_id),
           params: { reorder: { capability_id: @cap_a, target_id: SecureRandom.uuid_v7, placement: "after" } },
           as: :json

      assert_response :unprocessable_content
      assert_equal [ @cap_a, @cap_b, @cap_c ], graph_order
    end
  end

  context "POST create as non-admin member" do
    should "deny the reorder and leave the order untouched" do
      sign_in @member_user
      post framework_capability_reorders_path(framework_id: @framework_id),
           params: { reorder: { capability_id: @cap_c, target_id: @cap_a, placement: "before" } },
           as: :json

      assert_response :redirect
      assert_equal [ @cap_a, @cap_b, @cap_c ], graph_order
    end
  end
end
