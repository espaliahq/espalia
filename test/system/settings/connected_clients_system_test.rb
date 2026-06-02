# frozen_string_literal: true

require "application_system_test_case"

class Settings::ConnectedClientsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant, name: "Acme Corp")
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  context "user dropdown" do
    should "link to the AI assistants page" do
      visit root_path
      open_dropdown

      assert_selector "[role='menu'] a", text: "AI assistants", visible: true
      click_link_with_js_fallback("AI assistants", expect_text: "Connect an assistant")

      assert_text "MCP server URL"
    end
  end

  context "connect instructions" do
    should "show steps for each supported client" do
      visit settings_connected_clients_path
      assert_text "Connect an assistant"
      screenshot("ai_assistants_connect")

      assert_text "Claude Code"
      assert_text "Claude.ai & Claude Desktop"
      assert_text "ChatGPT"
      assert_text "Codex"
      assert_text "claude mcp add --transport http growthos"
    end

    should "give Copy feedback when copying a command" do
      visit settings_connected_clients_path
      assert_text "Connect an assistant"
      wait_for_stimulus "clipboard"

      # JS-dispatch the click — the button carries a Stimulus action, and a
      # synchronous element.click() bypasses pointer hit-testing (and the
      # FlakeProneClick cop) while still firing the controller's handler.
      page.execute_script(<<~JS)
        document
          .querySelector("[data-controller='clipboard'] [data-action='clipboard#copy']")
          .click();
      JS

      assert_text "Copied!"
    end
  end
end
