# frozen_string_literal: true

require "test_helper"

class HasTypeIdTest < ActiveSupport::TestCase
  # We piggy-back on TenantUser (the simplest UUID-keyed AR model in the
  # codebase that includes HasTypeId) rather than introduce a throwaway
  # AR class with its own table.
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    @tu = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user, role: :member)
    end
  end

  context "to_param" do
    should "return a TypeID string with the declared prefix" do
      param = @tu.to_param
      assert param.start_with?("tnu_"), "expected tnu_ prefix, got #{param.inspect}"
      assert_equal @tu.id, TypeID.from_string(param).uuid
    end

    should "return nil for an unpersisted record" do
      assert_nil TenantUser.new.to_param
    end
  end

  context "find" do
    should "look up by TypeID string" do
      assert_equal @tu, TenantUser.find(@tu.to_param)
    end

    should "still accept a raw UUID for backward compat" do
      assert_equal @tu, TenantUser.find(@tu.id)
    end

    should "raise RecordNotFound for an unknown TypeID" do
      unknown = TypeID.from_uuid("tnu", SecureRandom.uuid_v7).to_s
      assert_raises(ActiveRecord::RecordNotFound) { TenantUser.find(unknown) }
    end

    should "raise RecordNotFound (not TypeID::Error) for a malformed TypeID with the right prefix" do
      assert_raises(ActiveRecord::RecordNotFound) { TenantUser.find("tnu_not_valid_base32_!@#") }
    end

    should "fall through to default behavior for arrays" do
      assert_equal [ @tu ], TenantUser.find([ @tu.id ])
    end
  end

  context "find_by_typeid" do
    should "return the record for a valid TypeID" do
      assert_equal @tu, TenantUser.find_by_typeid(@tu.to_param)
    end

    should "return nil for a malformed TypeID instead of raising" do
      assert_nil TenantUser.find_by_typeid("not a real typeid")
    end

    should "return nil for an unknown TypeID" do
      unknown = TypeID.from_uuid("tnu", SecureRandom.uuid_v7).to_s
      assert_nil TenantUser.find_by_typeid(unknown)
    end
  end

  context "route helpers" do
    should "use TypeID in generated paths" do
      path = Rails.application.routes.url_helpers.tenant_user_path(@tu)
      assert_match(/\/tenant\/users\/tnu_[a-z0-9]+\z/, path)
    end
  end
end
