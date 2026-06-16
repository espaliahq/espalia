# frozen_string_literal: true

require "application_system_test_case"

# System coverage for the activity feed's "load older" pagination: when the
# framework stream exceeds the read cap, the feed shows a "Load older activity"
# affordance that appends the next batch (and bumps the running count) without a
# full reload.
class Frameworks::ActivityLoadMoreTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 1, "Engineer I", "E1", is_entry: true)
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      cap_id = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, role_id)
      handler.publish_version(@framework_id, "v1")
      handler.add_collaborator(@framework_id, @person.id.to_s, "owner", added_by: @person.id.to_s)

      # Pad the stream past the read cap so a second batch exists. These are raw
      # events (no projection dispatch) — the feed reads the stream directly.
      cap = Frameworks::ActivityFeedQuery::STREAM_READ_LIMIT
      padding = Array.new(cap + 10) do |i|
        Frameworks::Events::CapabilityAdded.new(
          data: { framework_id: @framework_id, capability_id: SecureRandom.uuid_v7, name: "pad-#{i}" },
          metadata: { tenant_id: @tenant.id }
        )
      end
      Rails.configuration.event_store.append(padding, stream_name: EventStreamNaming.framework_stream(@framework_id))
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@user)
  end

  should "append an older batch on demand and keep the count in step" do
    visit edit_framework_path(@framework_id)
    toggle_context_pane

    cap = Frameworks::ActivityFeedQuery::STREAM_READ_LIMIT
    within "#suggestion-panel" do
      # First batch is capped; the affordance signals there's more.
      assert_selector "#framework-activity-list > li", count: cap
      assert_text "#{cap} events"
      assert_selector "#framework-activity-load-more button", text: "Load older"
    end

    # JS-dispatch the click (hover-revealed control; pointer clicks flake on CI).
    page.execute_script(
      "document.querySelector(\"#framework-activity-load-more button[data-action='activity-more#load']\").click()"
    )

    within "#suggestion-panel" do
      # Older entries appended (more than the first capped batch) and the count grew.
      assert_selector "#framework-activity-list > li", minimum: cap + 1
      assert_no_text "#{cap} events"
    end
  end
end
