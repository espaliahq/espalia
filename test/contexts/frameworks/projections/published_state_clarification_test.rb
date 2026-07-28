# frozen_string_literal: true

require "test_helper"

# Projection coverage for the clarification (non-proposal) suggestion kind —
# the SuggestedEdit row shape on request and the resolve-with-note transition.
class Frameworks::Projections::PublishedStateClarificationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = Frameworks::Projections::PublishedState.new
    @framework_id = SecureRandom.uuid_v7
    @author = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
    @sid = SecureRandom.uuid_v7

    @cat_id = SecureRandom.uuid_v7
    @cap_id = SecureRandom.uuid_v7
    @eid = SecureRandom.uuid_v7
    emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "FW")
    emit(Frameworks::Events::CapabilityCategoryAdded,
      framework_id: @framework_id, category_id: @cat_id, name: "Thinking", ordinal: 1)
    emit(Frameworks::Events::CapabilityAdded,
      framework_id: @framework_id, capability_id: @cap_id, stable_id: SecureRandom.uuid_v7,
      category_id: @cat_id, name: "Strategic Thinking")
    emit(Frameworks::Events::BehaviouralExpectationSet,
      framework_id: @framework_id, expectation_id: @eid, stable_id: SecureRandom.uuid_v7,
      capability_id: @cap_id, level_ordinal: 4, description: "Shapes direction")
  end

  context "ClarificationRequested" do
    should "create a pending clarification row snapshotting the expectation text" do
      emit_clarification

      within_tenant do
        row = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "clarification", row.kind
        assert_equal "pending", row.status
        assert_equal "behavioural_expectation", row.target_entity_type
        assert_equal @eid, row.target_entity_id
        assert_equal "Shapes direction", row.current_value
        assert_nil row.suggested_value
        assert_nil row.field
        assert_equal "What does this mean?", row.rationale
        assert row.clarification?
        assert_not row.proposal?
      end
    end

    should "carry the level_ordinal in proposed_attributes for a capability anchor" do
      emit(Frameworks::Events::ClarificationRequested,
        framework_id: @framework_id, suggestion_id: @sid,
        target_entity_type: "capability", target_entity_id: @cap_id,
        level_ordinal: 5, author_id: @author.id, rationale: "Nothing defined at L5")

      within_tenant do
        row = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal({ "level_ordinal" => 5 }, row.proposed_attributes)
        assert_equal "Strategic Thinking", row.current_value
      end
    end
  end

  context "ClarificationResolved" do
    should "mark the row resolved with resolver, note, and resulting suggestion" do
      emit_clarification
      rsid = SecureRandom.uuid_v7
      emit(Frameworks::Events::ClarificationResolved,
        suggestion_id: @sid, resolver_id: @author.id,
        note: "Reworded L4", resulting_suggestion_id: rsid)

      within_tenant do
        row = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "resolved", row.status
        assert_equal @author.id, row.reviewed_by
        assert_equal "Reworded L4", row.reviewer_comment
        assert_equal rsid, row.resulting_suggestion_id
      end
    end
  end

  private

  def emit(event_class, **data)
    event = event_class.new(data: data, metadata: { tenant_id: @tenant.id })
    @projection.call(event)
  end

  def within_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def emit_clarification
    emit(Frameworks::Events::ClarificationRequested,
      framework_id: @framework_id, suggestion_id: @sid,
      target_entity_type: "behavioural_expectation", target_entity_id: @eid,
      author_id: @author.id, rationale: "What does this mean?")
  end
end
