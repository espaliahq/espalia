# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/placement_suggestion_fixture"

# Placement suggestions on the hub, at both viewports: the person the feedback
# is about accepts one and dismisses another without the page reloading, and
# adjusts the set in the evidence modal. The model is never called — the rows
# are written directly, as the job would.
class EvidencePlacementSuggestionsSystemTest < ApplicationSystemTestCase
  include PlacementSuggestionFixture

  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    build_placement_fixture
    @item = record_peer_feedback
    ActsAsTenant.with_tenant(@tenant) do
      @ownership_suggestion = create(:evidence_placement_suggestion, tenant: @tenant, item: @item,
        capability_stable_id: @ownership.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: 0.82)
      @collaboration_suggestion = create(:evidence_placement_suggestion, tenant: @tenant, item: @item,
        capability_stable_id: @collaboration.stable_id, level_ordinal: 4, valence: "growth_area", confidence: 0.4,
        rationale: "“kept everyone informed” speaks to collaboration.")
    end
  end

  def row(suggestion) = "li[data-suggestion-id='#{suggestion.id}']"

  def open_hub
    sign_in_as(@alex_user)
    visit evidence_hub_path
    assert_text "Adjust in the editor"
    page.execute_script("window.__hubNotReloaded = true")
  end

  def accept_and_dismiss
    assert_selector row(@ownership_suggestion), text: "82% confident"
    click_selector_with_js_fallback("#{row(@ownership_suggestion)} form[action$='/accept'] button",
                                    expect_text: "Placed on Ownership · E3 as Demonstrates.")
    assert_no_selector row(@ownership_suggestion)

    find("#{row(@collaboration_suggestion)} summary").click
    js_fill_in "#dismiss-reason-#{@collaboration_suggestion.id}", with: "This is about the incident, not teamwork"
    click_selector_with_js_fallback("#{row(@collaboration_suggestion)} form[action$='/dismiss'] button",
                                    expect_text: "Dismissed the suggestion to place it on Collaboration · E4.")
    assert_no_selector "li[data-suggestion-id]"
    assert page.evaluate_script("window.__hubNotReloaded"), "deciding a suggestion must not reload the hub"
  end

  def assert_decided
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal [ [ @ownership.stable_id, 3 ] ],
        EvidenceLink.active.where(evidence_id: @item.id).pluck(:capability_stable_id, :level_ordinal)
      assert_equal "This is about the incident, not teamwork", @collaboration_suggestion.reload.dismiss_reason
    end
  end

  should "accept and dismiss suggestions in place, on desktop" do
    open_hub
    accept_and_dismiss
    assert_decided
  end

  should "accept and dismiss suggestions in place, on mobile, without sideways scroll" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    open_hub
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
      "the suggestion rows must fit a phone"
    accept_and_dismiss
    assert_decided
  end

  should "stage the suggestions in the editor and keep the ones left" do
    open_hub
    click_button_with_js_fallback("Adjust in the editor", expect_text: "Edit feedback / evidence")
    assert_selector "[data-testid='suggested-row']", count: 2

    collaboration = find("[data-link-row]", text: "Collaboration")
    page.execute_script("arguments[0].querySelector(\"button[data-action*='removeLink']\").click()", collaboration)
    assert_selector "[data-testid='suggested-row']", count: 1

    click_selector_with_js_fallback("form[action='/evidence_items/#{@item.id}'] button[type='submit']",
                                    expect_text: "Feedback updated.")
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "edited", @ownership_suggestion.reload.status
      assert_equal "dismissed", @collaboration_suggestion.reload.status
    end
  end
end
