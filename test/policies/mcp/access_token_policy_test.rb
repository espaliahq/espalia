# frozen_string_literal: true

require "test_helper"

class Mcp::AccessTokenPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @owner = create(:user)
    @other = create(:user)

    @owner_ctx = AuthorizationContext.new(user: @owner, tenant_user: nil, person: nil)
    @other_ctx = AuthorizationContext.new(user: @other, tenant_user: nil, person: nil)
    @anon_ctx  = AuthorizationContext.new(user: nil,    tenant_user: nil, person: nil)

    @application = Mcp::Application.create!(
      name: "Test", redirect_uri: "https://x/cb",
      scopes: "read write", confidential: false
    )
    @token = Mcp::AccessToken.create!(
      application: @application, resource_owner_id: @owner.id,
      tenant_id: @tenant.id, scopes: "read write", expires_in: 3600
    )
  end

  context "index" do
    should "permit any signed-in user" do
      assert Mcp::AccessTokenPolicy.new(@owner_ctx, Mcp::AccessToken).index?
      assert Mcp::AccessTokenPolicy.new(@other_ctx, Mcp::AccessToken).index?
    end

    should "deny anonymous" do
      assert_not Mcp::AccessTokenPolicy.new(@anon_ctx, Mcp::AccessToken).index?
    end
  end

  context "destroy" do
    should "permit the token's resource owner" do
      assert Mcp::AccessTokenPolicy.new(@owner_ctx, @token).destroy?
    end

    should "deny another user" do
      assert_not Mcp::AccessTokenPolicy.new(@other_ctx, @token).destroy?
    end

    should "deny anonymous" do
      assert_not Mcp::AccessTokenPolicy.new(@anon_ctx, @token).destroy?
    end
  end
end
