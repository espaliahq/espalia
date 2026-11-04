# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/feedback_exchange_records"

# Feedback given in Chip waits under "Needs you" to be placed, and in the
# report's thread says where it came from, dates itself by when it was given,
# and opens the original.
class FeedbackExchangeImportSystemTest < ApplicationSystemTestCase
  include FeedbackExchangeRecords

  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = create(:tenant)
    connect_feedback_exchange(@tenant)
    @manager_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Reyes")
      @alex = create(:person, tenant: @tenant, email: "alex@example.com", name: "Alex Rivera", manager: @manager)
      create(:person, tenant: @tenant, email: "priya@example.com", name: "Priya Nair")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      PersonDevelopment::CommandHandler.new.assign_to_framework(@alex.id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      @result = FeedbackExchange::Importer.new(@tenant).import(exchange_record)
    end
  end

  def assert_imported_card
    visit evidence_hub_path
    assert_selector "#needs-you [data-testid='needs-you-place']", text: /Place Priya's feedback about Alex.*imported/m
    visit evidence_report_conversation_path(@alex.id)
    within("##{EvidenceItem.dom_id(@result.evidence_id)}") do
      assert_text(/Priya · 18 Oct/)
      assert_text "About Alex"
      assert_text "Great work on the incident call, calm and clear."
      assert_selector "strong", text: "Great"
      badge = find("a[data-origin='chip']", text: "via Chip")
      assert_equal "https://chip.example.com/feedback/chip-fb-0001", badge[:href]
      assert_equal "_blank", badge[:target]
      assert_button "Place on a capability"
    end
  end

  should "show imported feedback to place, via Chip, on desktop" do
    sign_in_as(@manager_user)
    assert_imported_card
  end

  should "show imported feedback to place, via Chip, on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@manager_user)
    assert_imported_card
    assert_no_sideways_overflow("the hub scrolls sideways on a phone")
  end
end
