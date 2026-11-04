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

  # The thread holding the item, through the link a notification sends.
  def open_hub(path = evidence_hub_item_path(@item.id))
    sign_in_as(@alex_user)
    visit path
    assert_text "Adjust in the editor"
    page.execute_script("window.__hubNotReloaded = true")
  end

  def accept_and_dismiss
    assert_selector row(@ownership_suggestion), text: "82% confident"
    click_selector_with_js_fallback("#{row(@ownership_suggestion)} form[action$='/accept'] button",
                                    expect_text: "Placed on Ownership · E3 as Demonstrates.")
    assert_no_selector row(@ownership_suggestion)

    # A dropped pointer click would leave the disclosure shut; open it directly.
    page.execute_script("arguments[0].open = true", find("#{row(@collaboration_suggestion)} details"))
    assert_selector "#dismiss-reason-#{@collaboration_suggestion.id}", visible: true
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

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |name, size|
    should "show a decision model's suggestion as its confidence alone, on #{name}" do
      page.driver.browser.manage.window.resize_to(*size)
      ActsAsTenant.with_tenant(@tenant) do
        @collaboration_suggestion.update!(rationale: nil, confidence: 0.57)
      end
      open_hub

      within(row(@collaboration_suggestion)) do
        assert_text "Collaboration · E4"
        assert_text "57% confident"
        assert_no_text "speaks to collaboration"
      end
      assert_text "Suggested by an AI model from the feedback."
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "the suggestion rows must fit the viewport"
      screenshot("#{name}_confidence_only")
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |name, size|
    should "let the assessee accept a suggestion on their own note to self, on #{name}" do
      page.driver.browser.manage.window.resize_to(*size)
      self_item = record_self_feedback
      self_suggestion = ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_placement_suggestion, tenant: @tenant, item: self_item,
          capability_stable_id: @ownership.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: 0.74,
          rationale: "“walked the team through every step” shows ownership of the rollout.")
      end
      open_hub(evidence_hub_item_path(self_item.id))

      within("##{EvidenceItem.dom_id(self_item.id)}") do
        assert_text(/note to self/i)
        assert_selector row(self_suggestion), text: "74% confident"
      end
      assert_no_sideways_overflow("the self feedback's suggestions must fit the #{name} viewport")
      screenshot("#{name}_self_feedback_suggestions")

      click_selector_with_js_fallback("#{row(self_suggestion)} form[action$='/accept'] button",
                                      expect_text: "Placed on Ownership · E3 as Demonstrates.")
      assert_no_selector row(self_suggestion)
      assert page.evaluate_script("window.__hubNotReloaded"), "deciding a suggestion must not reload the hub"
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal [ [ @collaboration.stable_id, 3 ], [ @ownership.stable_id, 3 ] ].sort,
          EvidenceLink.active.where(evidence_id: self_item.id).pluck(:capability_stable_id, :level_ordinal).sort
        assert_equal "accepted", self_suggestion.reload.status
      end
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |name, size|
    should "show every note's suggestions in the notes to self and accept one in place, on #{name}" do
      page.driver.browser.manage.window.resize_to(*size)
      items = (1..7).map do |n|
        item = travel_to(n.hours.ago) { record_self_feedback(content: "Self example #{n}: led the rollout review.") }
        ActsAsTenant.with_tenant(@tenant) do
          create(:evidence_placement_suggestion, tenant: @tenant, item: item, capability_stable_id: @ownership.stable_id,
            level_ordinal: 3, valence: "demonstrated", confidence: 0.7)
        end
        item
      end
      oldest = items.last
      suggestion = ActsAsTenant.with_tenant(@tenant) { EvidencePlacementSuggestion.find_by!(evidence_id: oldest.id) }

      open_hub(evidence_conversation_path(@alex.id))
      assert_selector "[data-testid='conversation-thread'] [data-testid='placement-suggestions']", count: 7
      assert_no_sideways_overflow("the notes must fit the #{name} viewport")

      click_selector_with_js_fallback("#{row(suggestion)} form[action$='/accept'] button",
                                      expect_text: "Placed on Ownership · E3 as Demonstrates.")
      assert_no_selector row(suggestion)
      assert page.evaluate_script("window.__hubNotReloaded"), "deciding a suggestion must not reload the page"
      screenshot("#{name}_notes_to_self_after_accept")
      ActsAsTenant.with_tenant(@tenant) { assert_equal "accepted", suggestion.reload.status }
    end
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
