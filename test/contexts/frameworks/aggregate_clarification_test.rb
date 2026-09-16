# frozen_string_literal: true

require "test_helper"

# Tests for the clarification (non-proposal suggestion) commands on the
# Framework aggregate — request / resolve, and the lifecycle guards that
# keep proposal verbs (approve / reject / amend) off clarifications.
class Frameworks::AggregateClarificationTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
    @aggregate.create(@framework_id, "Test Framework")

    @cat_id = SecureRandom.uuid_v7
    @cap_id = SecureRandom.uuid_v7
    @eid = SecureRandom.uuid_v7
    @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
    @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
    @aggregate.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, @cap_id, 4, "Shapes direction")

    @author_id = SecureRandom.uuid_v7
    @sid = SecureRandom.uuid_v7

    @aggregate.version = @aggregate.version
  end

  context "#request_clarification" do
    should "emit ClarificationRequested anchored on an expectation" do
      @aggregate.request_clarification(
        @framework_id, @sid, "behavioural_expectation", @eid,
        author_id: @author_id, rationale: "Raters read 'shapes direction' three different ways"
      )

      event = last_event
      assert_kind_of Frameworks::Events::ClarificationRequested, event
      assert_equal @sid, event.data[:suggestion_id]
      assert_equal "behavioural_expectation", event.data[:target_entity_type]
      assert_equal @eid, event.data[:target_entity_id]
      assert_equal @author_id, event.data[:author_id]
      assert_nil event.data[:level_ordinal]
    end

    should "carry the level_ordinal for a capability anchor" do
      @aggregate.request_clarification(
        @framework_id, @sid, "capability", @cap_id,
        author_id: @author_id, level_ordinal: 5, rationale: "Nothing defined at L5 — what does good look like?"
      )

      assert_equal 5, last_event.data[:level_ordinal]
      assert_equal "capability", last_event.data[:target_entity_type]
    end

    should "reject non-clarifiable entity types" do
      err = assert_raises(RuntimeError) do
        @aggregate.request_clarification(
          @framework_id, @sid, "capability_category", @cat_id,
          author_id: @author_id, rationale: "?"
        )
      end
      assert_match(/anchor on an expectation, capability, or example/, err.message)
    end

    should "reject a blank rationale — the question IS the clarification" do
      err = assert_raises(RuntimeError) do
        @aggregate.request_clarification(
          @framework_id, @sid, "behavioural_expectation", @eid,
          author_id: @author_id, rationale: "  "
        )
      end
      assert_match(/rationale cannot be blank/, err.message)
    end

    should "reject an unknown target entity" do
      assert_raises(RuntimeError) do
        @aggregate.request_clarification(
          @framework_id, @sid, "behavioural_expectation", SecureRandom.uuid_v7,
          author_id: @author_id, rationale: "?"
        )
      end
    end

    should "reject a duplicate suggestion_id" do
      request_clarification
      err = assert_raises(RuntimeError) { request_clarification }
      assert_match(/already exists/, err.message)
    end
  end

  context "#resolve_clarification" do
    setup { request_clarification }

    should "emit ClarificationResolved with the note" do
      @aggregate.resolve_clarification(@sid, @author_id, note: "Reworded L4 — see the linked suggestion",
                                       resulting_suggestion_id: (rsid = SecureRandom.uuid_v7))

      event = last_event
      assert_kind_of Frameworks::Events::ClarificationResolved, event
      assert_equal @sid, event.data[:suggestion_id]
      assert_equal @author_id, event.data[:resolver_id]
      assert_equal "Reworded L4 — see the linked suggestion", event.data[:note]
      assert_equal rsid, event.data[:resulting_suggestion_id]
    end

    should "reject a blank note" do
      err = assert_raises(RuntimeError) { @aggregate.resolve_clarification(@sid, @author_id, note: " ") }
      assert_match(/note cannot be blank/, err.message)
    end

    should "reject resolving twice" do
      @aggregate.resolve_clarification(@sid, @author_id, note: "Settled")
      assert_raises(RuntimeError) { @aggregate.resolve_clarification(@sid, @author_id, note: "Again") }
    end

    should "reject resolving a proposal-kind suggestion" do
      edit_sid = SecureRandom.uuid_v7
      @aggregate.suggest_edit(@framework_id, edit_sid, "behavioural_expectation", @eid,
                              "description", "New text", @author_id)

      err = assert_raises(RuntimeError) { @aggregate.resolve_clarification(edit_sid, @author_id, note: "n") }
      assert_match(/Only clarifications/, err.message)
    end
  end

  context "lifecycle guards" do
    setup { request_clarification }

    should "refuse approve on a clarification" do
      err = assert_raises(RuntimeError) { @aggregate.approve_suggestion(@sid, @author_id) }
      assert_match(/resolved with a note, not approved/, err.message)
    end

    should "refuse reject on a clarification" do
      err = assert_raises(RuntimeError) { @aggregate.reject_suggestion(@sid, @author_id) }
      assert_match(/resolved with a note, not rejected/, err.message)
    end

    should "refuse amend on a clarification" do
      err = assert_raises(RuntimeError) { @aggregate.amend_suggestion(@sid, "new value", @author_id) }
      assert_match(/no proposal to amend/, err.message)
    end

    should "allow the author to withdraw" do
      @aggregate.withdraw_suggestion(@sid, @author_id)
      assert_kind_of Frameworks::Events::SuggestionWithdrawn, last_event
    end

    should "allow comments on the clarification thread" do
      @aggregate.comment_on_suggestion(@framework_id, @sid, SecureRandom.uuid_v7,
                                       body: "I read it as scope, not altitude", author_id: @author_id)
      assert_kind_of Frameworks::Events::SuggestionCommented, last_event
    end

    should "not sweep a clarification when an archive of the same entity is approved" do
      cap_clar_sid = SecureRandom.uuid_v7
      @aggregate.request_clarification(
        @framework_id, cap_clar_sid, "capability", @cap_id,
        author_id: @author_id, level_ordinal: 2, rationale: "Unclear at L2"
      )
      delete_sid = SecureRandom.uuid_v7
      @aggregate.suggest_delete(@framework_id, delete_sid, "capability", @cap_id, author_id: @author_id)
      @aggregate.approve_suggestion(delete_sid, @author_id)

      rejected = new_events.select { |e| e.is_a?(Frameworks::Events::SuggestionRejected) }
      assert_empty rejected.select { |e| e.data[:suggestion_id] == cap_clar_sid },
        "archiving the capability must not auto-reject its clarification discussion"
    end
  end

  private

  def request_clarification
    @aggregate.request_clarification(
      @framework_id, @sid, "behavioural_expectation", @eid,
      author_id: @author_id, rationale: "What does 'shapes direction' mean at L4?"
    )
  end

  def new_events
    @aggregate.unpublished_events.to_a
  end

  def last_event
    @aggregate.unpublished_events.to_a.last
  end
end
