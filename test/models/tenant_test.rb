# frozen_string_literal: true

require "test_helper"

class TenantTest < ActiveSupport::TestCase
  subject { build(:tenant) }

  context "associations" do
    should have_many(:tenant_users).dependent(:destroy)
    should have_many(:users).through(:tenant_users)
    should have_many(:people).dependent(:destroy)
  end

  context "validations" do
    should validate_presence_of(:name)
    should validate_presence_of(:slug)
    should validate_uniqueness_of(:slug).ignoring_case_sensitivity
  end

  context "theme colour validations" do
    should allow_value("#ff0000").for(:primary_color)
    should allow_value("#FF00AA").for(:primary_color)
    should allow_value("").for(:primary_color)
    should allow_value(nil).for(:primary_color)
    should_not allow_value("red").for(:primary_color)
    should_not allow_value("#fff").for(:primary_color)
    should_not allow_value("#gggggg").for(:primary_color)
    should_not allow_value("inject;malicious").for(:primary_color)

    should allow_value("#00ff00").for(:secondary_color)
    should_not allow_value("blue").for(:secondary_color)

    should allow_value("#112233").for(:nav_bg_color)
    should allow_value("").for(:nav_bg_color)
    should_not allow_value("not-hex").for(:nav_bg_color)

    should allow_value("#ffffff").for(:nav_fg_color)
    should_not allow_value("white").for(:nav_fg_color)

    should allow_value("#ff0000").for(:primary_color_dark)
    should allow_value("").for(:primary_color_dark)
    should allow_value(nil).for(:primary_color_dark)
    should_not allow_value("red").for(:primary_color_dark)

    should allow_value("#00ff00").for(:secondary_color_dark)
    should_not allow_value("blue").for(:secondary_color_dark)

    should allow_value("#112233").for(:nav_bg_color_dark)
    should allow_value("").for(:nav_bg_color_dark)
    should_not allow_value("not-hex").for(:nav_bg_color_dark)

    should allow_value("#ffffff").for(:nav_fg_color_dark)
    should_not allow_value("white").for(:nav_fg_color_dark)

    should allow_value("Poppins").for(:font_family)
    should allow_value("Space Grotesk").for(:font_family)
    should allow_value("").for(:font_family)
    should allow_value(nil).for(:font_family)
    should_not allow_value("font;inject").for(:font_family)
    should_not allow_value("url(evil)").for(:font_family)
  end

  context "#theme_css_variables_light" do
    should "return empty hash when no colours set" do
      tenant = build(:tenant)
      assert_equal({}, tenant.theme_css_variables_light)
    end

    should "return primary variable when set" do
      tenant = build(:tenant, primary_color: "#ff0000")
      assert_equal({ "--color-primary" => "#ff0000" }, tenant.theme_css_variables_light)
    end

    should "return both variables when both set" do
      tenant = build(:tenant, primary_color: "#ff0000", secondary_color: "#00ff00")
      expected = { "--color-primary" => "#ff0000", "--color-secondary" => "#00ff00" }
      assert_equal expected, tenant.theme_css_variables_light
    end

    should "include nav colours when set" do
      tenant = build(:tenant, nav_bg_color: "#1e1b4b", nav_fg_color: "#e0e7ff")
      vars = tenant.theme_css_variables_light
      assert_equal "#1e1b4b", vars["--color-nav-bg"]
      assert_equal "#e0e7ff", vars["--color-nav-fg"]
    end

    should "include font-sans override when font_family set" do
      tenant = build(:tenant, font_family: "Poppins")
      vars = tenant.theme_css_variables_light
      assert_equal '"Poppins", ui-sans-serif, system-ui, sans-serif', vars["--font-sans"]
    end
  end

  context "#theme_css_variables_dark" do
    should "return empty hash when no dark colours set" do
      tenant = build(:tenant)
      assert_equal({}, tenant.theme_css_variables_dark)
    end

    should "return dark primary variable when set" do
      tenant = build(:tenant, primary_color_dark: "#ff6666")
      assert_equal({ "--color-primary" => "#ff6666" }, tenant.theme_css_variables_dark)
    end

    should "return all dark variables when set" do
      tenant = build(:tenant,
        primary_color_dark: "#ff6666", secondary_color_dark: "#66ff66",
        nav_bg_color_dark: "#111111", nav_fg_color_dark: "#eeeeee")
      vars = tenant.theme_css_variables_dark
      assert_equal "#ff6666", vars["--color-primary"]
      assert_equal "#66ff66", vars["--color-secondary"]
      assert_equal "#111111", vars["--color-nav-bg"]
      assert_equal "#eeeeee", vars["--color-nav-fg"]
    end

    should "include font-sans override when font_family set" do
      tenant = build(:tenant, font_family: "Poppins")
      vars = tenant.theme_css_variables_dark
      assert_equal '"Poppins", ui-sans-serif, system-ui, sans-serif', vars["--font-sans"]
    end
  end

  context "#google_font_url" do
    should "return nil when no font set" do
      tenant = build(:tenant)
      assert_nil tenant.google_font_url
    end

    should "return Google Fonts URL when font set" do
      tenant = build(:tenant, font_family: "Space Grotesk")
      assert_equal "https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;400;500;600;700&display=swap",
        tenant.google_font_url
    end
  end

  context "#evidence_suggestions_enabled?" do
    should "be off unless switched on" do
      assert_not build(:tenant).evidence_suggestions_enabled?
    end

    should "read a stored string as the boolean it names" do
      assert build(:tenant, evidence_suggestions_enabled: "true").evidence_suggestions_enabled?
      assert_not build(:tenant, evidence_suggestions_enabled: "false").evidence_suggestions_enabled?
    end
  end

  context "slug normalization" do
    should "downcase and replace invalid characters with dashes" do
      tenant = build(:tenant, slug: "ACME Corp!")
      tenant.valid?
      assert_equal "acme-corp", tenant.slug
    end

    should "strip leading/trailing dashes" do
      tenant = build(:tenant, slug: "-acme-")
      tenant.valid?
      assert_equal "acme", tenant.slug
    end

    should "normalize underscores to dashes" do
      tenant = build(:tenant, slug: "acme_corp")
      tenant.valid?
      assert_equal "acme-corp", tenant.slug
    end
  end

  context "Slack connection" do
    should "report not connected by default" do
      assert_not create(:tenant).slack_connected?
    end

    should "store the encrypted token + team on connect and expose helpers" do
      tenant = create(:tenant)
      tenant.connect_slack!(bot_token: "xoxb-1", team_id: "T1", team_name: "Acme HQ", installed_by: "person-1")

      assert tenant.slack_connected?
      assert_equal "xoxb-1", tenant.slack_bot_token
      assert_equal "Acme HQ", tenant.slack_team_name
      assert_equal "T1", tenant.slack_team_id
    end

    should "clear the connection and cached user ids on disconnect" do
      tenant = create(:tenant)
      tenant.connect_slack!(bot_token: "xoxb-1", team_id: "T1")
      membership = ActsAsTenant.with_tenant(tenant) do
        create(:tenant_user, tenant: tenant, user: create(:user)).tap { |tu| tu.update_column(:slack_user_id, "U1") }
      end

      tenant.disconnect_slack!

      assert_not tenant.reload.slack_connected?
      assert_nil tenant.slack_team_id
      assert_nil membership.reload.slack_user_id
    end
  end
end
