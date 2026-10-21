# frozen_string_literal: true

require "test_helper"

class EvidencePlacementSuggestionTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
  end

  teardown { ActsAsTenant.current_tenant = nil }

  subject { build(:evidence_placement_suggestion, tenant: @tenant) }

  context "validations" do
    should validate_inclusion_of(:status).in_array(EvidencePlacementSuggestion::STATUSES)
    should validate_inclusion_of(:valence).in_array(EvidenceLink::VALENCES)
    should allow_value(nil).for(:rationale)
    should validate_length_of(:rationale).is_at_most(EvidencePlacementSuggestion::RATIONALE_MAX_LENGTH)
    should validate_presence_of(:model)
    should validate_presence_of(:prompt_version)

    should "keep confidence between 0 and 1" do
      subject.confidence = 1.2
      assert_not subject.valid?
      subject.confidence = 0
      assert subject.valid?
    end

    should "refuse a second row for the same item and cell" do
      first = create(:evidence_placement_suggestion, tenant: @tenant)
      duplicate = build(:evidence_placement_suggestion, tenant: @tenant, evidence_id: first.evidence_id,
        capability_stable_id: first.capability_stable_id, level_ordinal: first.level_ordinal)
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
    end
  end

  context "#decide!" do
    should "record who decided, when and why" do
      suggestion = create(:evidence_placement_suggestion, tenant: @tenant)
      person = create(:person, tenant: @tenant)

      suggestion.decide!(status: "dismissed", by: person, reason: "Not about delivery")

      suggestion.reload
      assert_equal "dismissed", suggestion.status
      assert_equal person.id, suggestion.decided_by_id
      assert_not_nil suggestion.decided_at
      assert_equal "Not about delivery", suggestion.dismiss_reason
    end

    should "refuse a status that is not a decision" do
      suggestion = create(:evidence_placement_suggestion, tenant: @tenant)
      assert_raises(ArgumentError) { suggestion.decide!(status: "pending", by: create(:person, tenant: @tenant)) }
    end
  end

  context ".pending_by_evidence" do
    should "group pending rows per item, most confident first" do
      evidence_id = SecureRandom.uuid_v7
      low = create(:evidence_placement_suggestion, tenant: @tenant, evidence_id: evidence_id, confidence: 0.4)
      high = create(:evidence_placement_suggestion, tenant: @tenant, evidence_id: evidence_id, confidence: 0.9)
      create(:evidence_placement_suggestion, tenant: @tenant, evidence_id: evidence_id, status: "dismissed")

      assert_equal [ high, low ], EvidencePlacementSuggestion.pending_by_evidence([ evidence_id ])[evidence_id]
    end
  end
end
