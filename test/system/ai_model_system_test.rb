# frozen_string_literal: true

require "application_system_test_case"

class AiModelSystemTest < ApplicationSystemTestCase
  KEY = "sk-gateway-secret-key-1234567890"

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @member_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |name, size|
    context "on #{name}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "set up Jev on the Vercel AI Gateway from the Integrations card and test the connection" do
        sign_in_as(@admin_user)
        visit tenant_integrations_path
        assert_text "AI model"
        assert_text "Not configured"
        screenshot("#{name}_card_not_configured")

        click_link_with_js_fallback "AI model", expect_text: "A stored key is never shown"
        wait_for_stimulus "ai-model-preset"
        assert_no_horizontal_overflow
        assert_selector "#ai_model_effort", visible: true
        screenshot("#{name}_page_empty")

        choose_preset "vercel_ai_gateway_chat"
        assert_equal "openai_compatible", find_by_id("ai_model_provider").value
        assert_equal "anthropic/claude-opus-5-5", find_by_id("ai_model_model").value

        choose_preset "vercel_ai_gateway"
        assert_equal "https://ai-gateway.vercel.sh/v1", find_by_id("ai_model_base_url").value
        assert_equal "typesafe-ai/jev", find_by_id("ai_model_model").value
        assert_equal "typesafe_jev", find_by_id("ai_model_provider").value
        assert_no_selector "#ai_model_effort", visible: true
        js_fill_in "ai_model_api_key", with: KEY
        page.execute_script("document.getElementById('ai_model_suggestions_enabled').checked = true")
        screenshot("#{name}_form_gateway")
        click_button_with_js_fallback "Save settings", expect_text: "AI model settings saved."

        assert_text "Active"
        assert_no_text KEY
        assert_equal "", find_by_id("ai_model_api_key").value
        assert_equal "Leave blank to keep it", find_by_id("ai_model_api_key")[:placeholder]
        assert_equal "vercel_ai_gateway", find_by_id("ai_model_preset").value
        assert_no_horizontal_overflow
        screenshot("#{name}_page_active")

        adapter = Object.new
        adapter.define_singleton_method(:model) { "typesafe-ai/jev" }
        adapter.define_singleton_method(:ping) { "yes, 98% sure this is a connection check" }
        Ai::ModelClient.stub(:for, adapter) do
          click_button_with_js_fallback "Test connection", expect_text: "replied: “yes, 98% sure this is a connection check”"
        end
        assert_text "Jev (TypeSafe AI)"
        assert_no_horizontal_overflow
        screenshot("#{name}_connection_ok")

        visit tenant_integrations_path
        assert_text "typesafe-ai/jev · ai-gateway.vercel.sh"
        assert_text "Active"
        assert_no_horizontal_overflow
        screenshot("#{name}_card_active")
      end

      should "show a rejected key when the endpoint refuses it" do
        @tenant.update_ai_model!(settings: { suggestions_enabled: true }, api_key: KEY)
        sign_in_as(@admin_user)
        visit tenant_integration_path("ai-model")
        assert_text "A stored key is never shown"

        rejecting = Object.new
        rejecting.define_singleton_method(:model) { "claude-opus-5-5" }
        rejecting.define_singleton_method(:ping) { raise Ai::Errors::AuthenticationError }
        Ai::ModelClient.stub(:for, rejecting) do
          click_button_with_js_fallback "Test connection", expect_text: "rejected the API key"
        end
        screenshot("#{name}_connection_rejected")
      end

      should "show an error beside a bad address and keep what was typed" do
        sign_in_as(@admin_user)
        visit tenant_integration_path("ai-model")
        wait_for_stimulus "ai-model-preset"

        choose_preset "openai_compatible"
        js_fill_in "ai_model_base_url", with: "http://gateway.example.com/v1"
        js_fill_in "ai_model_model", with: "some/model"
        click_button_with_js_fallback "Save settings", expect_text: "The settings could not be saved."

        assert_text "must start with https://"
        assert_equal "http://gateway.example.com/v1", find_by_id("ai_model_base_url").value
        assert_no_horizontal_overflow
        screenshot("#{name}_error")
      end

      should "keep the page away from a member" do
        sign_in_as(@member_user)
        visit tenant_integration_path("ai-model")

        assert_current_path root_path
        assert_text "You are not authorized to perform this action"
      end
    end
  end

  private

  def choose_preset(key)
    page.execute_script(<<~JS)
      const select = document.getElementById("ai_model_preset")
      select.value = #{key.to_json}
      select.dispatchEvent(new Event("change", { bubbles: true }))
    JS
  end

  def assert_no_horizontal_overflow
    overflowing = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("body *"))
        .filter((el) => el.getBoundingClientRect().right > window.innerWidth + 1)
        .slice(0, 5)
        .map((el) => el.tagName.toLowerCase() + "." + String(el.className).slice(0, 60))
    JS
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
           "the page scrolls sideways; wider than the viewport: #{overflowing.inspect}"
  end
end
