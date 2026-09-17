# frozen_string_literal: true

require "test_helper"

class Tenant::VocabulariesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user  = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "GET /tenant/vocabulary" do
      should "render the editor with the shipped word as the placeholder" do
        get tenant_vocabulary_path

        assert_response :success
        assert_includes response.body, "Vocabulary"
        assert_includes response.body, "Mastering"
      end
    end

    context "PATCH /tenant/vocabulary" do
      should "rename the state" do
        patch tenant_vocabulary_path, params: { tenant: { mastering_label: "Advancing" } }

        assert_redirected_to tenant_vocabulary_path
        assert_equal "Advancing", @tenant.reload.mastering_label
      end

      should "clear an override back to the shipped word" do
        ActsAsTenant.with_tenant(@tenant) { @tenant.update!(mastering_label: "Advancing") }

        patch tenant_vocabulary_path, params: { tenant: { mastering_label: "" } }

        assert_nil @tenant.reload.mastering_label.presence
      end

      should "surface an over-long label rather than saving it" do
        patch tenant_vocabulary_path, params: { tenant: { mastering_label: "A" * 25 } }

        assert_redirected_to tenant_vocabulary_path
        assert_match(/24 characters/, flash[:alert])
        assert_nil @tenant.reload.mastering_label.presence
      end
    end
  end

  context "as a non-admin member" do
    setup { sign_in @member_user }

    should "redirect from the editor" do
      get tenant_vocabulary_path

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "refuse the write" do
      patch tenant_vocabulary_path, params: { tenant: { mastering_label: "Advancing" } }

      assert_redirected_to root_path
      assert_nil @tenant.reload.mastering_label.presence
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
