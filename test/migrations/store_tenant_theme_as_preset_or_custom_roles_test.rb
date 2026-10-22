# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261021010000_store_tenant_theme_as_preset_or_custom_roles")

# Runs the migration against tenants shaped as they were before it: the
# columns are dropped inside the test's transaction (Postgres DDL is
# transactional), so the schema comes back when the test rolls back.
class StoreTenantThemeAsPresetOrCustomRolesTest < ActiveSupport::TestCase
  Row = StoreTenantThemeAsPresetOrCustomRoles::TenantRow

  setup do
    connection = ActiveRecord::Base.connection
    connection.remove_column :tenants, :custom_theme
    connection.remove_column :tenants, :theme
    Row.reset_column_information
  end

  teardown do
    Row.reset_column_information
    Tenant.reset_column_information
  end

  should "make a tenant with today's settings Custom, carrying brand, nav and font across" do
    themed = legacy_tenant("themed", {
      "primary_color" => "#00362F", "primary_color_dark" => "#5ee0a0",
      "secondary_color" => "#001814", "secondary_color_dark" => "#3a9a6a",
      "nav_bg_color" => "#DBFC45", "nav_bg_color_dark" => "#0a1f1a",
      "nav_fg_color" => "#001814", "nav_fg_color_dark" => "#DBFC45",
      "font_family" => "Zalando Sans Regular"
    })

    migrate_up
    themed.reload

    assert_equal "custom", themed.theme
    assert_equal({
      "brand" => { "light" => "#00362F", "dark" => "#5ee0a0" },
      "nav-surface" => { "light" => "#DBFC45", "dark" => "#0a1f1a" }
    }, themed.custom_theme)
    assert_equal({ "font_family" => "Zalando Sans Regular" }, themed.settings)
  end

  should "keep only the schemes a tenant set" do
    light_only = legacy_tenant("light-only", { "primary_color" => "#6366f1" })

    migrate_up

    assert_equal({ "brand" => { "light" => "#6366f1" } }, light_only.reload.custom_theme)
  end

  should "make a font-only tenant Custom, so the font still applies" do
    font_only = legacy_tenant("font-only", { "font_family" => "Poppins" })

    migrate_up
    font_only.reload

    assert_equal "custom", font_only.theme
    assert_equal({}, font_only.custom_theme)
    assert_equal "Poppins", font_only.settings["font_family"]
  end

  should "leave a tenant with no theme settings on Default" do
    plain = legacy_tenant("plain", { "unrelated" => "kept" })

    migrate_up
    plain.reload

    assert_equal "default", plain.theme
    assert_equal({}, plain.custom_theme)
    assert_equal({ "unrelated" => "kept" }, plain.settings)
  end

  should "restore primary and nav background on the way down" do
    themed = legacy_tenant("round-trip", { "primary_color" => "#112233", "nav_bg_color_dark" => "#445566" })

    migrate_up
    StoreTenantThemeAsPresetOrCustomRoles.new.tap { |m| m.verbose = false }.down
    Row.reset_column_information

    assert_equal({ "primary_color" => "#112233", "nav_bg_color_dark" => "#445566" }, themed.reload.settings)
  end

  private

  def legacy_tenant(slug, settings)
    Row.create!(id: SecureRandom.uuid_v7, name: slug, slug: slug, settings: settings)
  end

  def migrate_up
    StoreTenantThemeAsPresetOrCustomRoles.new.tap { |m| m.verbose = false }.up
    Row.reset_column_information
  end
end
