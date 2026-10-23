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

  context "theme" do
    should "default to the Default theme" do
      assert_equal "default", Tenant.new.theme
    end

    should allow_value("default", "bento", "custom").for(:theme)
    should_not allow_value("neon", "", nil).for(:theme)

    should "set data-theme only for a preset" do
      assert_equal "bento", build(:tenant, theme: "bento").theme_preset
      assert_nil build(:tenant, theme: "default").theme_preset
      assert_nil build(:tenant, theme: "custom").theme_preset
    end
  end

  context "custom_theme validations" do
    should "read the roles a Custom theme can set from the hooks in roles.css" do
      assert_equal %w[brand nav-surface], Tenant::CUSTOM_ROLES
    end

    should "read each role's Default value per scheme from its hook's fallback" do
      assert_equal({ "light" => "#32c8c8", "dark" => "#5ee0e0" }, Tenant::CUSTOM_ROLE_DEFAULTS["brand"])
      assert_equal(
        { "light" => Tenant::DEFAULT_NAV_BG_COLOR, "dark" => Tenant::DEFAULT_NAV_BG_COLOR_DARK },
        Tenant::CUSTOM_ROLE_DEFAULTS["nav-surface"]
      )
    end

    should allow_value({ "brand" => { "light" => "#FF00aa", "dark" => "#112233" } }).for(:custom_theme)
    should allow_value({ "nav-surface" => { "light" => "#112233" } }).for(:custom_theme)
    should allow_value({}).for(:custom_theme)

    should_not allow_value({ "secondary" => { "light" => "#112233" } }).for(:custom_theme)
    should_not allow_value({ "brand" => { "light" => "#fff" } }).for(:custom_theme)
    should_not allow_value({ "brand" => { "light" => "red" } }).for(:custom_theme)
    should_not allow_value({ "brand" => { "light" => "#000000;}body{" } }).for(:custom_theme)
    should_not allow_value({ "brand" => { "sepia" => "#112233" } }).for(:custom_theme)
    should_not allow_value({ "brand" => "#112233" }).for(:custom_theme)
    should_not allow_value({ "brand" => [ "#112233" ] }).for(:custom_theme)
    should_not allow_value([ [ "brand", { "light" => "#112233" } ] ]).for(:custom_theme)

    should "drop blank values and roles left empty" do
      tenant = build(:tenant, custom_theme: { brand: { light: "#112233", dark: "" }, "nav-surface" => { light: nil } })
      assert_equal({ "brand" => { "light" => "#112233" } }, tenant.custom_theme)
    end
  end

  context "font_family validations" do
    should allow_value("Poppins", "Space Grotesk", "", nil).for(:font_family)
    should_not allow_value("font;inject", "url(evil)").for(:font_family)
  end

  context "#custom_role" do
    should "return the tenant's value for a Custom theme, and nil where Default's applies" do
      tenant = build(:tenant, theme: "custom", custom_theme: { "brand" => { "light" => "#112233" } })
      assert_equal "#112233", tenant.custom_role("brand", :light)
      assert_nil tenant.custom_role("brand", :dark)
      assert_nil tenant.custom_role("nav-surface", :light)
    end

    should "ignore stored values when the theme is not Custom" do
      tenant = build(:tenant, theme: "default", custom_theme: { "brand" => { "light" => "#112233" } })
      assert_nil tenant.custom_role("brand", :light)
    end
  end

  context "#theme_css_variables" do
    should "emit nothing for Default or a preset, whatever is stored" do
      stored = { custom_theme: { "brand" => { "light" => "#112233" } }, font_family: "Poppins" }
      assert_equal({}, build(:tenant, theme: "default", **stored).theme_css_variables)
      assert_equal({}, build(:tenant, theme: "bento", **stored).theme_css_variables)
    end

    should "emit scheme-suffixed variables for each value a Custom theme sets, and its font" do
      tenant = build(:tenant, theme: "custom", font_family: "Poppins", custom_theme: {
        "brand" => { "light" => "#112233", "dark" => "#445566" },
        "nav-surface" => { "light" => "#778899" }
      })

      assert_equal({
        "--tenant-brand" => "#112233",
        "--tenant-brand-dark" => "#445566",
        "--tenant-nav-surface" => "#778899",
        "--font-sans" => '"Poppins", ui-sans-serif, system-ui, sans-serif'
      }, tenant.theme_css_variables)
    end

    should "name only variables roles.css reads" do
      css = Tenant::ROLES_STYLESHEET.read
      Tenant::CUSTOM_ROLES.each do |role|
        assert_includes css, "var(--tenant-#{role},"
        assert_includes css, "var(--tenant-#{role}-dark,"
      end
    end
  end

  context ".browser_theme_color" do
    should "use Default's navbar with no tenant and on Default" do
      [ nil, build(:tenant) ].each do |tenant|
        assert_equal Tenant::DEFAULT_NAV_BG_COLOR, Tenant.browser_theme_color(tenant, :light)
        assert_equal Tenant::DEFAULT_NAV_BG_COLOR_DARK, Tenant.browser_theme_color(tenant, :dark)
      end
    end

    should "use a preset's own navbar" do
      tenant = build(:tenant, theme: "bento")
      assert_equal "#c6f226", Tenant.browser_theme_color(tenant, :light)
      assert_equal "#c6f226", Tenant.browser_theme_color(tenant, :dark)
    end

    should "hold a navbar in both schemes for every preset" do
      Tenant::PRESETS.each do |preset|
        assert_equal %w[dark light], Tenant::NAV_SURFACES.fetch(preset).keys.sort, preset
      end
    end

    should "use a Custom theme's nav surface, and Default's for a blank scheme" do
      tenant = build(:tenant, theme: "custom", custom_theme: { "nav-surface" => { "light" => "#123456" } })
      assert_equal "#123456", Tenant.browser_theme_color(tenant, :light)
      assert_equal Tenant::DEFAULT_NAV_BG_COLOR_DARK, Tenant.browser_theme_color(tenant, :dark)
    end
  end

  context "#google_font_url" do
    should "return nil when no font set" do
      assert_nil build(:tenant, theme: "custom").google_font_url
    end

    should "return the Google Fonts URL for a Custom theme's font" do
      tenant = build(:tenant, theme: "custom", font_family: "Space Grotesk")
      assert_equal "https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;400;500;600;700&display=swap",
        tenant.google_font_url
    end

    should "return nil on a theme that carries its own font" do
      assert_nil build(:tenant, theme: "bento", font_family: "Space Grotesk").google_font_url
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

      should "allow changing the model, effort and switch without re-entering the key" do
        tenant = create(:tenant, :with_ai_model)

        tenant.update_ai_model!(settings: { model: "claude-haiku-5-5", effort: "", suggestions_enabled: false })

        assert_equal [ "claude-haiku-5-5", "", false ],
                     [ tenant.reload.ai_config.model, tenant.ai_config.effort, tenant.ai_config.suggestions_enabled? ]
      end

      should "load and save a stored config that still carries the retired name switch" do
        tenant = create(:tenant, :with_ai_model)
        stored = tenant.read_attribute_before_type_cast(:ai_config)
        stored = stored.is_a?(String) ? JSON.parse(stored) : stored
        [ true, false ].each do |value|
          Tenant.where(id: tenant.id).update_all(ai_config: stored.merge("pseudonymise_names" => value))
          tenant.reload

          assert tenant.ai_config.valid?
          tenant.update!(name: "Renamed #{value}")
          tenant.update_ai_model!(settings: { model: "claude-haiku-5-5" })
          assert_equal "claude-haiku-5-5", tenant.reload.ai_config.model
          assert_not_includes tenant.read_attribute_before_type_cast(:ai_config).to_s, "pseudonymise_names"
        end
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
