# frozen_string_literal: true

require "test_helper"

class PagesPolicyTest < ActiveSupport::TestCase
  context "#index?" do
    should "permit any authenticated user" do
      user = build(:user)
      ctx = AuthorizationContext.new(user: user, tenant_user: nil, person: nil)

      assert PagesPolicy.new(ctx, :pages).index?
    end

    should "deny when there is no user" do
      ctx = AuthorizationContext.new(user: nil, tenant_user: nil, person: nil)

      assert_not PagesPolicy.new(ctx, :pages).index?
    end
  end
end
