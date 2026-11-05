# frozen_string_literal: true

require "test_helper"

# What the platform is called (#660): each tenant can name it for their own
# people (settings["product_name"]); tenant-less surfaces fall back to the
# instance default (config.x.product_name, from PRODUCT_NAME).
class ProductNameTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @original = Rails.application.config.x.product_name
    Rails.application.config.x.product_name = "Acme Growth"
  end

  teardown do
    Rails.application.config.x.product_name = @original
  end

  context "the sign-in page (tenant-less)" do
    should "take its heading, title and application-name from the instance default" do
      get new_user_session_path

      assert_response :success
      assert_includes response.body, ">Acme Growth</h1>"
      assert_includes response.body, %(<meta name="application-name" content="Acme Growth">)
      assert_includes response.body, "<title>Acme Growth</title>"
    end
  end

  context "a tenant that names the platform itself" do
    setup do
      @tenant = create(:tenant, product_name: "Ladder")
      @user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user) }
      sign_in @user
    end

    should "carry the tenant's name through the navbar, title and application-name" do
      get root_path

      assert_response :success
      assert_includes response.body, "#{@tenant.name} Ladder"
      assert_includes response.body, %(<meta name="application-name" content="Ladder">)
      assert_includes response.body, "· Ladder</title>"
      assert_not_includes response.body, "Acme Growth"
    end
  end

  context "Tenant#product_name" do
    should "fall back to the instance default when unset or blank" do
      assert_equal "Acme Growth", build(:tenant).product_name
      assert_equal "Acme Growth", build(:tenant, product_name: "").product_name
      assert_equal "Ladder", build(:tenant, product_name: "Ladder").product_name
    end

    should "reject a name over 60 characters" do
      assert_not build(:tenant, product_name: "x" * 61).valid?
    end

    should "not judge tenants by the instance default's length" do
      Rails.application.config.x.product_name = "y" * 80

      assert build(:tenant).valid?
      assert_equal "y" * 80, build(:tenant).product_name
    end
  end
end
