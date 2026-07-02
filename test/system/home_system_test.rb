# frozen_string_literal: true

require "application_system_test_case"

class HomeSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  context "home dashboard" do
    should "render the dashboard greeting and an empty state when nothing is pending" do
      visit root_path

      assert_text "Home"
      assert_text "Nothing needs your attention right now."
    end

    should "surface the recent-activity card when the viewer has assessment activity" do
      framework_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        # sign_in_as already auto-created the viewer's Person (by email); reuse it.
        person = Person.find_or_create_by!(tenant: @tenant, email: @user.email) { |p| p.name = "Me" }
        category = FactoryBot.create(:framework_capability_category, framework_id: framework_id)
        cap = FactoryBot.create(:framework_capability, category_id: category.category_id, name: "Critical Thinking")
        FactoryBot.create(:person_framework_assignment,
          tenant: @tenant, person_id: person.id, framework_id: framework_id)
        FactoryBot.create(:evidence_item,
          tenant: @tenant, person_id: person.id, framework_id: framework_id,
          capability_stable_id: cap.stable_id, level_ordinal: 2, recorded_at: Time.current,
          author: person)
      end

      visit root_path

      # The card lazy-loads its content; assert_text waits for the frame fetch.
      assert_text "Recent activity"
      assert_text "added feedback to"
      assert_text "Critical Thinking"
    end

    should "surface the evidence-requests card when a colleague has asked the viewer for evidence" do
      ActsAsTenant.with_tenant(@tenant) do
        # sign_in_as already auto-created the viewer's Person (by email); reuse it.
        me = Person.find_or_create_by!(tenant: @tenant, email: @user.email) { |p| p.name = "Me" }
        asker = FactoryBot.create(:person, tenant: @tenant, name: "Casey Asker")
        EvidenceRequest.create!(
          id: SecureRandom.uuid_v7, tenant: @tenant, person_id: asker.id,
          framework_id: SecureRandom.uuid_v7, requested_by_id: asker.id,
          requestee_person_id: me.id, capability_stable_id: SecureRandom.uuid_v7,
          level_ordinal: 2, status: "pending", requested_at: Time.current
        )
      end

      visit root_path

      # The card lazy-loads its content; assert_text waits for the frame fetch.
      assert_text "Feedback / Evidence requested of you"
      assert_text "Casey Asker"
      assert_link "Respond →"
    end
  end

  context "page layout shell on /frameworks" do
    should "hide sidebar drawer by default on mobile and toggle it with hamburger" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit frameworks_path

      assert_selector "[data-sidebar-target='drawer']", visible: :all
      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      classes = drawer[:class].split
      assert_includes classes, "hidden", "sidebar drawer should be hidden on mobile by default"

      toggle_sidebar

      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      classes = drawer[:class].split
      assert_not_includes classes, "hidden",
        "sidebar drawer should be visible after hamburger click"
    end

    should "close mobile menu when clicking outside" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit frameworks_path

      toggle_sidebar

      # JS-dispatched MouseEvent bubbles to the window capture-phase listener
      # stimulus-use's useClickOutside registers. Selenium's synthetic pointer
      # events (action.move_to_location.click) do not reliably trigger that
      # listener on headless Chrome under load — same fix as the framework
      # explorer outside-click test.
      dispatch_outside_click = lambda do
        page.execute_script(<<~JS)
          const main = document.querySelector("main") || document.body;
          main.dispatchEvent(new MouseEvent("click", {
            bubbles: true, cancelable: true, view: window
          }))
        JS
      end

      dispatch_outside_click.call

      drawer_visible = -> {
        find("[data-sidebar-target='drawer']", visible: :all)[:class].split.exclude?("hidden")
      }
      dispatch_outside_click.call if drawer_visible.call

      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      assert_includes drawer[:class].split, "hidden",
        "sidebar drawer should close when clicking outside"
    end

    should "hide hamburger button on desktop" do
      visit frameworks_path

      assert_no_selector "[data-action='sidebar#toggle']"
    end
  end
end
