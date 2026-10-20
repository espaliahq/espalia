# frozen_string_literal: true

require "test_helper"

class ColorSchemePolicyTest < ActiveSupport::TestCase
  should "let any signed-in user change their own" do
    assert ColorSchemePolicy.new(AuthorizationContext.new(user: build(:user), tenant_user: nil, person: nil), :color_scheme).update?
  end

  should "refuse without a user" do
    assert_not ColorSchemePolicy.new(AuthorizationContext.new(user: nil, tenant_user: nil, person: nil), :color_scheme).update?
  end
end
