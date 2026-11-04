# frozen_string_literal: true

require "test_helper"

class HrisConfigTest < ActiveSupport::TestCase
  context "validations" do
    should "accept valid providers" do
      config = HrisConfig.new(provider: "hibob")
      config.valid?
      assert_empty config.errors[:provider]
    end

    should "reject a provider no adapter dispatches to" do
      config = HrisConfig.new(provider: "bamboohr")
      assert_not config.valid?
      assert_not_empty config.errors[:provider]
    end

    should "name a provider for people" do
      assert_equal "HiBob", HrisConfig.provider_label("hibob")
      assert_equal "Not configured", HrisConfig.provider_label(nil)
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

  context "role_mappings" do
    should "default to empty array" do
      config = HrisConfig.new
      assert_equal [], config.role_mappings
    end

    should "accept valid role mappings with and without level_ordinal" do
      config = HrisConfig.new(
        role_mappings: [
          HrisRoleMapping.new(hris_titles: [ "Senior SWE" ], framework_role_code: "E", level_ordinal: 5),
          HrisRoleMapping.new(hris_titles: [ "Engineering Manager" ], framework_role_code: "EM")
        ]
      )
      assert_equal 2, config.role_mappings.size
      assert config.valid?
    end

    should "reject mappings when the same title appears twice" do
      config = HrisConfig.new(
        role_mappings: [
          HrisRoleMapping.new(hris_titles: [ "Senior SWE" ], framework_role_code: "E", level_ordinal: 5),
          HrisRoleMapping.new(hris_titles: [ "senior swe" ], framework_role_code: "EM", level_ordinal: 3)
        ]
      )
      assert_not config.valid?
      assert_not_empty config.errors[:role_mappings]
    end
  end

  context "level_field_id" do
    should "default to nil" do
      config = HrisConfig.new
      assert_nil config.level_field_id
    end

    should "accept a custom column id" do
      config = HrisConfig.new(level_field_id: "column_0000000000000")
      assert_equal "column_0000000000000", config.level_field_id
    end
  end

  context "title mapping" do
    setup do
      @config = HrisConfig.new(role_mappings: [
        HrisRoleMapping.new(hris_titles: [ "Engineering Manager", "Senior Engineering Manager" ], framework_role_code: "EM"),
        HrisRoleMapping.new(hris_titles: [ "Staff Engineer" ], framework_role_code: "E", level_ordinal: 6)
      ])
    end

    should "resolve a title case-insensitively and with its ends trimmed" do
      assert_equal "EM", @config.mapping_for("  engineering MANAGER ").framework_role_code
      assert_nil @config.mapping_for("Engineering Manager (EM3)")
    end

    should "join the mapping that already has that role and level source" do
      @config.map_title("Engineering Manager (EM3)", framework_role_code: "EM")

      assert_equal 2, @config.role_mappings.size
      assert_equal [ "Engineering Manager", "Senior Engineering Manager", "Engineering Manager (EM3)" ],
        @config.role_mappings.first.hris_titles
    end

    should "start a new mapping for a role and level source nobody uses yet" do
      @config.map_title("Analytics Lead", framework_role_code: "AE", level_ordinal: 3)

      mapping = @config.mapping_for("Analytics Lead")
      assert_equal [ "AE", 3 ], [ mapping.framework_role_code, mapping.level_ordinal ]
      assert_equal 3, @config.role_mappings.size
    end

    should "move a title rather than list it twice" do
      @config.map_title("staff engineer", framework_role_code: "EM")

      assert_equal "EM", @config.mapping_for("Staff Engineer").framework_role_code
      assert_equal 1, @config.role_mappings.size, "the emptied E6 mapping is dropped"
      assert @config.valid?
    end

    should "treat a fixed level and the HRIS level column as different mappings" do
      @config.map_title("Engineering Manager", framework_role_code: "EM", level_ordinal: 4)

      assert_equal 4, @config.mapping_for("Engineering Manager").level_ordinal
      assert_nil @config.mapping_for("Senior Engineering Manager").level_ordinal
    end

    should "remove a title and drop a mapping it empties" do
      @config.unmap_title("STAFF ENGINEER")

      assert_nil @config.mapping_for("Staff Engineer")
      assert_equal [ "EM" ], @config.role_mappings.map(&:framework_role_code)
    end

    should "leave the config unchanged when unmapping a title nobody mapped" do
      before = @config.role_mappings.map(&:as_json)
      @config.unmap_title("Chief Vibes Officer")

      assert_equal before, @config.role_mappings.map(&:as_json)
    end

    should "persist through the tenant" do
      tenant = create(:tenant, :with_hibob_config)
      tenant.hris_config.map_title("Analytics Lead", framework_role_code: "AE", level_ordinal: 3)
      tenant.save!

      assert_equal "AE", tenant.reload.hris_config.mapping_for("analytics lead").framework_role_code
    end
  end
end
