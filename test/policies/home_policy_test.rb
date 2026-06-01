# frozen_string_literal: true

require "test_helper"

class HomePolicyTest < ActiveSupport::TestCase
  context "#show? and #card?" do
    should "permit any authenticated user" do
      ctx = AuthorizationContext.new(user: build(:user), tenant_user: nil, person: nil)

      assert HomePolicy.new(ctx, :home).show?
      assert HomePolicy.new(ctx, :home).card?
    end

    should "deny when there is no user" do
      ctx = AuthorizationContext.new(user: nil, tenant_user: nil, person: nil)

      assert_not HomePolicy.new(ctx, :home).show?
      assert_not HomePolicy.new(ctx, :home).card?
    end
  end
end
