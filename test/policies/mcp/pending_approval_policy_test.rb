# frozen_string_literal: true

require "test_helper"

class Mcp::PendingApprovalPolicyTest < ActiveSupport::TestCase
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
    @approval = Mcp::PendingApproval.create!(
      user: @owner, tenant: @tenant, client_application: @application,
      operation_class: "Operations::System::Whoami", arguments: {},
      expires_at: Time.current + 1.hour
    )
  end

  context "as the user who initiated the approval" do
    should "permit show, approve, reject" do
      policy = Mcp::PendingApprovalPolicy.new(@owner_ctx, @approval)
      assert policy.show?
      assert policy.approve?
      assert policy.reject?
    end
  end

  context "as a different signed-in user" do
    should "deny show, approve, reject" do
      policy = Mcp::PendingApprovalPolicy.new(@other_ctx, @approval)
      assert_not policy.show?
      assert_not policy.approve?
      assert_not policy.reject?
    end
  end

  context "anonymous" do
    should "deny show, approve, reject" do
      policy = Mcp::PendingApprovalPolicy.new(@anon_ctx, @approval)
      assert_not policy.show?
      assert_not policy.approve?
      assert_not policy.reject?
    end
  end
end
