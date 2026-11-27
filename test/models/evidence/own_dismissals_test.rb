# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

class Evidence::OwnDismissalsTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  REASON = "Wrong behaviour for this one"

  setup do
    build_placement_fixture
    ActsAsTenant.current_tenant = @tenant
    @item = record_peer_feedback
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "give the viewer their own dismissal, with its reason, date and cell name" do
    dismiss_on(@ownership, by: @jordan, reason: REASON)

    entry = Evidence::OwnDismissals.for([ @item ], @jordan.id).fetch(@item.id)
    dismissal = entry[:dismissals].sole

    assert_equal REASON, dismissal.dismiss_reason
    assert_equal @ownership.stable_id, dismissal.capability_stable_id
    assert_not_nil dismissal.decided_at
    assert_equal "Ownership", entry[:cells].fetch(dismissal.id)[:name]
  end

  should "leave out a dismissal someone else made, even for a viewer who sees the whole assessment" do
    dismiss_on(@ownership, by: @morgan, reason: REASON)

    assert_empty Evidence::OwnDismissals.for([ @item ], @jordan.id)
    assert_empty Evidence::OwnDismissals.for([ @item ], @alex.id)
  end

  should "give a viewer with no person nothing" do
    dismiss_on(@ownership, by: @jordan, reason: REASON)

    assert_empty Evidence::OwnDismissals.for([ @item ], nil)
  end

  should "keep a dismissal with no reason" do
    dismiss_on(@ownership, by: @jordan, reason: "")

    assert_nil Evidence::OwnDismissals.for([ @item ], @jordan.id).fetch(@item.id)[:dismissals].sole.dismiss_reason
  end

  should "leave out pending and accepted suggestions" do
    suggest_on(@collaboration)

    assert_empty Evidence::OwnDismissals.for([ @item ], @jordan.id)
  end

  should "give nothing about a forgotten person, and read no stream to find that out" do
    dismiss_on(@ownership, by: @jordan, reason: REASON)
    @alex.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)

    refusing = Object.new
    def refusing.read = raise("the hub must not read a development stream")
    Rails.configuration.stub(:event_store, refusing) do
      assert_empty Evidence::OwnDismissals.for([ @item ], @jordan.id)
    end
  end

  should "read no stream for a remembered person either" do
    dismiss_on(@ownership, by: @jordan, reason: REASON)

    refusing = Object.new
    def refusing.read = raise("the hub must not read a development stream")
    Rails.configuration.stub(:event_store, refusing) do
      assert_equal 1, Evidence::OwnDismissals.for([ @item ], @jordan.id).fetch(@item.id)[:dismissals].size
    end
  end

  private

  def suggest_on(capability)
    PersonDevelopment::Repository.new.with_person_development(@alex.id, @framework_id) do |aggregate|
      aggregate.suggest_placements(@item.id, proposals: [
        { capability_stable_id: capability.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: "0.8",
          rationale: "Kept everyone informed." }
      ], provider: "anthropic", model: "test-model", prompt_version: "v1", generated_at: "2026-11-24T10:00:00Z")
    end
    EvidencePlacementSuggestion.pending.for_evidence(@item.id).find_by!(capability_stable_id: capability.stable_id)
  end

  def dismiss_on(capability, by:, reason:)
    suggestion = suggest_on(capability)
    PersonDevelopment::Repository.new.with_person_development(@alex.id, @framework_id) do |aggregate|
      aggregate.dismiss_suggestion(suggestion.id, evidence_id: @item.id, dismissed_by_id: by.id, reason: reason)
    end
  end
end
