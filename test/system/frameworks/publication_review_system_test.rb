# frozen_string_literal: true

require "application_system_test_case"

# The publish-review page: every retiring capability's migration mapping is
# edited in ONE form, so choosing on one row never loses the others (#399), and
# the confirm button cannot request the same publish twice.
class Frameworks::PublicationReviewSystemTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      @legacy_id = SecureRandom.uuid_v7
      @tools_id = SecureRandom.uuid_v7
      @legacy_stable_id = SecureRandom.uuid_v7
      @tools_stable_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @legacy_id, @legacy_stable_id, cat_id, "Legacy Systems")
      handler.add_capability(@framework_id, @tools_id, @tools_stable_id, cat_id, "Old Tools")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cat_id, "Modern Platforms")
      handler.publish_version(@framework_id, "test") # v1: all three exist
      handler.archive_capability(@framework_id, @legacy_id, reason: "x") # auto-opens v2
      handler.archive_capability(@framework_id, @tools_id, reason: "x")
    end
  end

  def mappings
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::MigrationMapping.where(framework_id: @framework_id) }
  end

  should "save the choices made on every row in one submit" do
    sign_in_as(@admin_user)
    visit new_framework_publication_path(@framework_id)
    assert_text "Retiring 2 capabilities"
    assert_selector "span", text: "Needs a mapping", count: 2

    legacy = find("div[data-controller='mapping-form']", text: "Legacy Systems")
    tools  = find("div[data-controller='mapping-form']", text: "Old Tools")

    within(legacy) do
      select "Evolved — into a survivor", from: "Mapping"
      select "Modern Platforms", from: "Survivor"
    end
    within(tools) do
      select "Archived — no replacement", from: "Mapping"
    end

    click_button "Save mappings"

    assert_text "Saved 2 mappings."
    assert_no_text "Needs a mapping"
    assert_equal 2, mappings.count
    assert_equal "evolved", mappings.find_by(from_stable_id: @legacy_stable_id).mapping_type
    assert_equal "archived", mappings.find_by(from_stable_id: @tools_stable_id).mapping_type

    # Both rows come back showing what was saved.
    within(find("div[data-controller='mapping-form']", text: "Legacy Systems")) do
      assert_select_value "Mapping", "evolved"
      assert_select_value "Survivor", "Modern Platforms"
    end
    within(find("div[data-controller='mapping-form']", text: "Old Tools")) do
      assert_select_value "Mapping", "archived"
    end
  end

  should "refuse to publish while a row still needs a mapping, then publish in the background once mapped" do
    sign_in_as(@admin_user)
    visit new_framework_publication_path(@framework_id)

    click_button "Confirm & publish v2"
    assert_text "Add a migration mapping before publishing: Legacy Systems and Old Tools."

    within(find("div[data-controller='mapping-form']", text: "Legacy Systems")) do
      select "Archived — no replacement", from: "Mapping"
    end
    within(find("div[data-controller='mapping-form']", text: "Old Tools")) do
      select "Archived — no replacement", from: "Mapping"
    end
    click_button "Save mappings"
    assert_text "Saved 2 mappings."

    click_button "Confirm & publish v2"
    assert_text "Publishing v2 in the background"
    assert_button "Publishing v2…", disabled: true

    # Coming back to the review page while the job is queued shows the state
    # and offers no second confirm.
    visit new_framework_publication_path(@framework_id)
    assert_text "Publishing v2…"
    assert_no_button "Confirm & publish v2"

    perform_enqueued_jobs(only: Frameworks::PublishVersionJob)
    visit edit_framework_path(@framework_id)
    assert_no_text "v2 draft"
  end

  private

  # The selected option's visible text or value for a labelled select.
  def assert_select_value(label, expected)
    selected = find_field(label).find("option[selected]", visible: :all) rescue nil
    value = selected ? selected.text.presence || selected.value : find_field(label).value
    assert_includes [ selected&.text, selected&.value, value ].compact, expected
  end
end
