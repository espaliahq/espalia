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

        wait_for_stimulus "all-kinds"
        assert_checked "feedback_exchange_export_kinds_all"
        assert_checked "feedback_exchange_import_kinds_all"
        assert_selector "#feedback_exchange_export_kinds_impact:checked:disabled"
        assert_selector "#feedback_exchange_import_kinds_feedback:checked:disabled"
        screenshot("#{name}_kinds_all")

        click_checkbox "feedback_exchange_export_kinds_all"
        assert_selector "#feedback_exchange_export_kinds_impact:checked:enabled"
        click_checkbox "feedback_exchange_export_kinds_impact"
        assert_selector "#feedback_exchange_import_kinds_feedback:disabled"
        screenshot("#{name}_form_filled")
        click_button_with_js_fallback "Save settings", expect_text: "Feedback exchange settings saved."

        assert_text "Active"
        assert_no_text OUTBOUND
        assert_no_text INBOUND
        assert_no_checked "feedback_exchange_export_kinds_all"
        assert_no_checked "feedback_exchange_export_kinds_impact"
        assert_checked "feedback_exchange_export_kinds_observation"
        assert_checked "feedback_exchange_import_kinds_all"
        assert_equal EvidenceItem::EVIDENCE_TYPES - %w[impact], @tenant.reload.feedback_exchange_config.export_kinds
        assert_equal %w[all], @tenant.feedback_exchange_config.import_kinds
        assert_equal "", find_by_id("feedback_exchange_outbound_secret").value
        assert_equal Views::Integrations::Concerns::SettingsFields::SECRET_PLACEHOLDER, find_by_id("feedback_exchange_outbound_secret")[:placeholder]
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
        @tenant.update_feedback_exchange!(outbound_secret: OUTBOUND, inbound_secret: INBOUND)
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

      should "grey out a chosen list under All types, give it back when All is unticked, and save All" do
        @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(peer_name: "chip", base_url: PEER,
                                                                             import_kinds: %w[peer_feedback]))
        sign_in_as(@admin_user)
        visit tenant_integration_path("feedback-exchange")
        assert_text "Stored secrets are never shown"
        wait_for_stimulus "all-kinds"

        assert_no_checked "feedback_exchange_import_kinds_all"
        assert_selector "#feedback_exchange_import_kinds_peer_feedback:checked:enabled"
        assert_selector "#feedback_exchange_import_kinds_impact:not(:checked):enabled"

        click_checkbox "feedback_exchange_import_kinds_all"
        assert_selector "#feedback_exchange_import_kinds_impact:checked:disabled"
        assert_no_horizontal_overflow
        screenshot("#{name}_import_all_over_a_list")

        click_checkbox "feedback_exchange_import_kinds_all"
        assert_selector "#feedback_exchange_import_kinds_impact:not(:checked):enabled"
        assert_checked "feedback_exchange_import_kinds_peer_feedback"

        click_checkbox "feedback_exchange_import_kinds_all"
        assert_selector "#feedback_exchange_import_kinds_impact:checked:disabled"
        click_button_with_js_fallback "Save settings", expect_text: "Feedback exchange settings saved."

        assert_checked "feedback_exchange_import_kinds_all"
        assert_equal %w[all], @tenant.reload.feedback_exchange_config.import_kinds
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

  # A JS click fires the change event the all-kinds controller listens for,
  # without the pointer hit-testing that drops clicks on a starved runner. Not
  # click_selector_with_js_fallback: a late first click plus its fallback would
  # toggle the box twice.
  def click_checkbox(id)
    assert_selector "##{id}", visible: :all
    page.execute_script("document.getElementById(arguments[0]).click()", id)
  end

  def assert_checked(id)
    assert_selector "##{id}:checked"
  end

  def assert_no_checked(id)
    assert_selector "##{id}", visible: :all
    assert_no_selector "##{id}:checked"
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
