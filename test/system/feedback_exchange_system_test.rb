# frozen_string_literal: true

require "application_system_test_case"

class FeedbackExchangeSystemTest < ApplicationSystemTestCase
  PEER = "https://chip.example.com/api/feedback-exchange"
  OUTBOUND = "outbound-secret-outbound-secret-xx"
  INBOUND = "inbound-secret-inbound-secret-inbound"

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

      should "configure the exchange from the Integrations card and test the connection" do
        sign_in_as(@admin_user)
        visit tenant_integrations_path
        assert_text "Feedback exchange"
        assert_text "Not configured"
        screenshot("#{name}_card_not_configured")

        click_link_with_js_fallback "Feedback exchange", expect_text: "Stored secrets are never shown"
        assert_no_horizontal_overflow
        screenshot("#{name}_page_empty")

        js_fill_in "feedback_exchange_peer_name", with: "chip"
        js_fill_in "feedback_exchange_base_url", with: PEER
        js_fill_in "feedback_exchange_outbound_secret", with: OUTBOUND
        js_fill_in "feedback_exchange_inbound_secret", with: INBOUND
        page.execute_script("document.getElementById('feedback_exchange_enabled').checked = true")
        screenshot("#{name}_form_filled")
        click_button_with_js_fallback "Save settings", expect_text: "Feedback exchange settings saved."

        assert_text "Active"
        assert_no_text OUTBOUND
        assert_no_text INBOUND
        assert_equal "", find_by_id("feedback_exchange_outbound_secret").value
        assert_equal "Leave blank to keep the stored value", find_by_id("feedback_exchange_outbound_secret")[:placeholder]
        assert_no_horizontal_overflow
        screenshot("#{name}_page_active")

        healthy = Object.new
        healthy.define_singleton_method(:health) { { "ok" => true, "peer" => "chip" } }
        FeedbackExchange::Client.stub(:for, healthy) do
          click_button_with_js_fallback "Test connection", expect_text: "Connected to chip"
        end
        screenshot("#{name}_connection_ok")

        visit tenant_integrations_path
        assert_text "Feedback shared with chip"
        assert_text "Active"
        assert_no_horizontal_overflow
        screenshot("#{name}_card_active")
      end

      should "show a refused signature when the peer rejects ours" do
        @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(peer_name: "chip", base_url: PEER))
        @tenant.update_feedback_exchange_secrets!(outbound_secret: OUTBOUND, inbound_secret: INBOUND)
        sign_in_as(@admin_user)
        visit tenant_integration_path("feedback-exchange")
        assert_text "Stored secrets are never shown"

        rejecting = Object.new
        rejecting.define_singleton_method(:health) { raise FeedbackExchange::Errors::AuthenticationError }
        FeedbackExchange::Client.stub(:for, rejecting) do
          click_button_with_js_fallback "Test connection", expect_text: "rejected our signature"
        end
        screenshot("#{name}_connection_rejected")
      end

      should "keep the page away from a member" do
        sign_in_as(@member_user)
        visit tenant_integration_path("feedback-exchange")

        assert_current_path root_path
        assert_text "You are not authorized to perform this action"
      end
    end
  end

  private

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
           "the page scrolls sideways"
  end
end
