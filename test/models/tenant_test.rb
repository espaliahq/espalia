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

    should "follow the AI model card's switch" do
      assert build(:tenant, :with_ai_model).evidence_suggestions_enabled?
    end

    should "honour the switch the earlier settings key stored, for one more release" do
      assert build(:tenant, settings: { "evidence_suggestions_enabled" => "true" }).evidence_suggestions_enabled?
      assert_not build(:tenant, settings: { "evidence_suggestions_enabled" => "false" }).evidence_suggestions_enabled?
    end
  end

  context "the AI model" do
    should "keep its key out of inspect, to_s and the config" do
      tenant = build(:tenant, :with_ai_model)

      assert_equal "sk-test-key", tenant.ai_secrets.api_key
      assert_no_match(/sk-test-key/, tenant.ai_secrets.inspect)
      assert_no_match(/sk-test-key/, tenant.ai_secrets.to_s)
      assert_no_match(/sk-test-key/, tenant.ai_config.to_json)
    end

    should "encrypt the key at rest" do
      tenant = create(:tenant, :with_ai_model)

      raw = Tenant.connection.select_value("SELECT ai_credentials FROM tenants WHERE id = '#{tenant.id}'")
      assert_no_match(/sk-test-key/, raw)
    end

    should "fall back to the deployment's Anthropic key only for a tenant on the legacy switch" do
      credentials = Rails.application.credentials
      credentials.stub(:dig, ->(*path) { path == [ :anthropic, :api_key ] ? "sk-deployment" : nil }) do
        assert_nil build(:tenant).ai_api_key
        assert_equal "sk-deployment", build(:tenant, settings: { "evidence_suggestions_enabled" => true }).ai_api_key
        assert_equal "sk-test-key", build(:tenant, :with_ai_model, settings: { "evidence_suggestions_enabled" => true }).ai_api_key
        custom = build(:tenant, settings: { "evidence_suggestions_enabled" => true }, ai_config: AiModelConfig.new(base_url: "https://proxy.example.com"))
        assert_nil custom.ai_api_key, "the deployment key never goes to a tenant-chosen address"
        gateway = build(:tenant, settings: { "evidence_suggestions_enabled" => true },
                                 ai_config: AiModelConfig.new(provider: "openai_compatible", base_url: "https://gw.example.com/v1", model: "a/b"))
        assert_nil gateway.ai_api_key
      end
    end

    context "#update_ai_model!" do
      should "save settings and key, and keep the stored key when the new one is blank" do
        tenant = create(:tenant)
        tenant.update_ai_model!(settings: { provider: "openai_compatible", base_url: "https://gw.example.com/v1", model: "a/b" }, api_key: " sk-one ")
        tenant.reload

        assert_equal "openai_compatible", tenant.ai_config.provider
        assert_equal "sk-one", tenant.ai_secrets.api_key

        tenant.update_ai_model!(settings: { suggestions_enabled: true }, api_key: "")
        tenant.reload

        assert tenant.ai_config.suggestions_enabled?
        assert_equal "a/b", tenant.ai_config.model
        assert_equal "sk-one", tenant.ai_secrets.api_key
      end

      should "drop the legacy settings keys, folding them into the form first" do
        tenant = create(:tenant, settings: { "evidence_suggestions_enabled" => true, "evidence_suggestions_model" => "claude-haiku-5-5", "font_family" => "Inter" })

        form = tenant.effective_ai_config
        assert form.suggestions_enabled?
        assert_equal "claude-haiku-5-5", form.model

        tenant.update_ai_model!(settings: { suggestions_enabled: false, model: "claude-opus-5-5" })
        tenant.reload

        assert_not tenant.legacy_evidence_suggestions_enabled?
        assert_not tenant.evidence_suggestions_enabled?
        assert_equal "Inter", tenant.font_family
      end

      should "refuse to point a stored key at another provider or address without a new key" do
        tenant = create(:tenant, :with_ai_model)

        error = assert_raises(ActiveRecord::RecordInvalid) { tenant.update_ai_model!(settings: { base_url: "https://proxy.example.com" }) }
        assert_includes error.message, "Enter the API key again"
        assert_equal "sk-test-key", tenant.reload.ai_secrets.api_key
        assert_nil tenant.ai_config.base_url

        tenant.update_ai_model!(settings: { base_url: "https://proxy.example.com" }, api_key: "sk-moved")
        assert_equal "sk-moved", tenant.reload.ai_secrets.api_key
      end

      should "allow changing the model, effort and switches without re-entering the key" do
        tenant = create(:tenant, :with_ai_model)

        tenant.update_ai_model!(settings: { model: "claude-haiku-5-5", effort: "", suggestions_enabled: false, pseudonymise_names: false })

        assert_equal [ "claude-haiku-5-5", "", false, false ],
                     [ tenant.reload.ai_config.model, tenant.ai_config.effort, tenant.ai_config.suggestions_enabled?, tenant.ai_config.pseudonymise_names? ]
      end

      should "refuse suggestions with no key, and not raise on a non-string key" do
        tenant = create(:tenant)

        assert_raises(ActiveRecord::RecordInvalid) { tenant.update_ai_model!(settings: { suggestions_enabled: true }, api_key: [ "x" ]) }
        assert_raises(ActiveRecord::RecordInvalid) { tenant.update_ai_model!(settings: { suggestions_enabled: true }) }
        assert_nothing_raised { tenant.update_ai_model!(settings: { suggestions_enabled: false }, api_key: [ "x" ]) }
      end

      should "work again on the same instance after a refused save, starting from what is stored" do
        tenant = create(:tenant, :with_ai_model)

        assert_raises(ActiveRecord::RecordInvalid) { tenant.update_ai_model!(settings: { base_url: "https://proxy.example.com" }) }
        assert_raises(ActiveRecord::RecordInvalid) do
          tenant.update_ai_model!(settings: { provider: "openai_compatible", base_url: "http://gw.example.com", model: "a/b" }, api_key: "sk-x")
        end

        tenant.update_ai_model!(settings: { model: "claude-haiku-5-5" })
        tenant.reload

        assert_equal "claude-haiku-5-5", tenant.ai_config.model
        assert_equal "anthropic", tenant.ai_config.provider, "the refused attempts left nothing behind"
        assert_nil tenant.ai_config.base_url
        assert_equal "sk-test-key", tenant.ai_secrets.api_key
      end

      should "raise on an invalid config and store nothing" do
        tenant = create(:tenant)

        assert_raises(ActiveRecord::RecordInvalid) do
          tenant.update_ai_model!(settings: { provider: "openai_compatible", base_url: "http://gw.example.com", model: "a/b" }, api_key: "sk-x")
        end
        assert_nil tenant.reload.ai_secrets.api_key
      end
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
