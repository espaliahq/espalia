# frozen_string_literal: true

require "test_helper"

class HrisConfigTest < ActiveSupport::TestCase
  context "validations" do
    should "accept valid providers" do
      config = HrisConfig.new(provider: "hibob")
      config.valid?
      assert_empty config.errors[:provider]
    end

    should "accept bamboohr provider" do
      config = HrisConfig.new(provider: "bamboohr")
      config.valid?
      assert_empty config.errors[:provider]
    end

    should "reject unknown providers" do
      config = HrisConfig.new(provider: "unknown")
      assert_not config.valid?
      assert_not_empty config.errors[:provider]
    end

    should "allow blank provider" do
      config = HrisConfig.new(provider: "")
      config.valid?
      assert_empty config.errors[:provider]
    end
  end

  context "#configured?" do
    should "return true when provider, credentials, and sync_enabled are set" do
      tenant = create(:tenant, :with_hibob_config)

      assert tenant.hris_config.configured?(tenant)
    end

    should "return false without credentials" do
      tenant = create(:tenant)
      tenant.hris_config = HrisConfig.new(provider: "hibob", sync_enabled: true)

      assert_not tenant.hris_config.configured?(tenant)
    end

    should "return false when sync_enabled is false" do
      tenant = create(:tenant, :with_hibob_config)
      tenant.hris_config.sync_enabled = false

      assert_not tenant.hris_config.configured?(tenant)
    end

    should "return false without provider" do
      tenant = create(:tenant)
      tenant.hris_config = HrisConfig.new(sync_enabled: true)
      tenant.hris_credentials = { "service_user_id" => "x", "api_token" => "y" }

      assert_not tenant.hris_config.configured?(tenant)
    end
  end

  context "field_mappings" do
    should "default to empty array" do
      config = HrisConfig.new
      assert_equal [], config.field_mappings
    end

    should "accept valid field mappings" do
      config = HrisConfig.new(
        field_mappings: [ HrisFieldMapping.new(hris_field: "work.custom", person_field: "department") ]
      )
      assert_equal 1, config.field_mappings.size
    end
  end
end
