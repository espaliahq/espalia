# frozen_string_literal: true

require "test_helper"

class Frameworks::ActivityFeedQueryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @framework = create(:framework_state, tenant: @tenant)
    @fwid = @framework.framework_id

    @cat = create(:framework_capability_category,
      framework_id: @fwid, tenant: @tenant, name: "Thinking")
    @other_cat = create(:framework_capability_category,
      framework_id: @fwid, tenant: @tenant, name: "Delivery")

    @cap = create(:framework_capability,
      category_id: @cat.category_id, tenant: @tenant, name: "Strategic Thinking")
    @other_cap = create(:framework_capability,
      category_id: @other_cat.category_id, tenant: @tenant, name: "Delivery Focus")

    @exp = create(:framework_behavioural_expectation,
      capability_id: @cap.capability_id, tenant: @tenant, level_ordinal: 2)
    @ill = create(:framework_role_illustration,
      expectation_id: @exp.expectation_id, tenant: @tenant)

    @actor = create(:person, tenant: @tenant, name: "Ada Author")
    @reviewer = create(:person, tenant: @tenant, name: "Rita Reviewer")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  # Appends a raw event to the framework stream with tenant + actor metadata.
  def append(event_class, data:, actor_id: nil)
    event = event_class.new(data: { framework_id: @fwid }.merge(data),
                            metadata: { tenant_id: @tenant.id, actor_id: actor_id }.compact)
    Rails.configuration.event_store.append(
      event, stream_name: EventStreamNaming.framework_stream(@fwid)
    )
    event
  end

  def entries(**kwargs)
    Frameworks::ActivityFeedQuery.new(framework: @framework, **kwargs).call
  end

  context "suggestion lifecycle" do
    setup do
      @suggestion_id = SecureRandom.uuid_v7
      @suggestion = create(:framework_suggested_edit,
        tenant: @tenant, framework_id: @fwid, suggestion_id: @suggestion_id,
        target_entity_type: "capability", target_entity_id: @cap.capability_id,
        field: "description", kind: "edit", author_id: @actor.id)
    end

    should "emit a suggestion_edit entry anchored to the capability with payload actor" do
      append(Frameworks::Events::EditSuggested,
        data: { suggestion_id: @suggestion_id, target_entity_type: "capability",
                target_entity_id: @cap.capability_id, field: "description",
                suggested_value: "Better text", author_id: @actor.id },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "suggestion_edit" }
      assert entry, "expected a suggestion_edit entry"
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "Strategic Thinking", entry.capability_name
      assert_equal "Ada Author", entry.actor_name
      assert_equal "capability", entry.payload[:suggestion_entity_type]
    end

    should "carry the suggestion id, status, and entity type for the actionable overlay" do
      append(Frameworks::Events::EditSuggested,
        data: { suggestion_id: @suggestion_id, target_entity_type: "capability",
                target_entity_id: @cap.capability_id, field: "description",
                suggested_value: "Better text", author_id: @actor.id },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "suggestion_edit" }
      assert_equal @suggestion_id, entry.suggestion_id
      assert_equal "pending", entry.suggestion_status
      assert_equal "capability", entry.suggestion_entity_type
    end

    should "anchor approved/withdrawn lifecycle events via the SuggestedEdit row" do
      append(Frameworks::Events::SuggestionApproved,
        data: { suggestion_id: @suggestion_id, reviewer_id: @reviewer.id },
        actor_id: @reviewer.id)
      append(Frameworks::Events::SuggestionWithdrawn,
        data: { suggestion_id: @suggestion_id }, actor_id: @actor.id)

      approved = entries.find { |e| e.kind == "suggestion_approved" }
      assert approved
      assert_equal @cap.capability_id, approved.capability_id
      assert_equal "Rita Reviewer", approved.actor_name, "reviewer resolved from payload"

      withdrawn = entries.find { |e| e.kind == "suggestion_withdrawn" }
      assert withdrawn
      assert_equal @cap.capability_id, withdrawn.capability_id
      assert_equal "Ada Author", withdrawn.actor_name, "actor resolved from metadata"
    end
  end

  context "structural & editorial" do
    should "anchor capability_archived to its capability + category, actor from metadata" do
      append(Frameworks::Events::CapabilityArchived,
        data: { capability_id: @cap.capability_id, reason: "merged" },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "capability_archived" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "Ada Author", entry.actor_name
    end

    should "anchor an expectation_updated to its parent capability" do
      append(Frameworks::Events::BehaviouralExpectationUpdated,
        data: { expectation_id: @exp.expectation_id, new_description: "x", rationale: "y" })

      entry = entries.find { |e| e.kind == "expectation_updated" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
    end

    should "anchor an illustration_updated to its grandparent capability" do
      append(Frameworks::Events::RoleIllustrationUpdated,
        data: { illustration_id: @ill.illustration_id, new_description: "x", rationale: "y" })

      entry = entries.find { |e| e.kind == "illustration_updated" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
    end

    should "anchor a category_updated to the category only" do
      append(Frameworks::Events::CapabilityCategoryUpdated,
        data: { category_id: @cat.category_id, name: "Renamed" })

      entry = entries.find { |e| e.kind == "category_updated" }
      assert entry
      assert_nil entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "Thinking", entry.payload[:category_name]
    end
  end

  context "framework-level events" do
    should "carry nil anchors and surface only at framework focus" do
      append(Frameworks::Events::FrameworkVersionPublished,
        data: { version: 2, published_by: @actor.id }, actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "version_published" }
      assert entry
      assert_nil entry.capability_id
      assert_nil entry.category_id
      assert_equal "Ada Author", entry.actor_name

      assert_empty entries(focus: :capability, capability_id: @cap.capability_id)
        .select { |e| e.kind == "version_published" }
    end

    should "not crash on the bootstrap draft's non-uuid started_by" do
      append(Frameworks::Events::DraftVersionStarted,
        data: { target_version: 1, started_by: "system" })

      entry = entries.find { |e| e.kind == "draft_opened" }
      assert entry
      assert_nil entry.actor_name
    end
  end

  context "focus filtering" do
    setup do
      append(Frameworks::Events::CapabilityUpdated,
        data: { capability_id: @cap.capability_id, name: "A" })
      append(Frameworks::Events::CapabilityUpdated,
        data: { capability_id: @other_cap.capability_id, name: "B" })
    end

    should "show all entries at framework focus" do
      assert_equal 2, entries.count { |e| e.kind == "capability_updated" }
    end

    should "narrow to one capability at capability focus" do
      result = entries(focus: :capability, capability_id: @cap.capability_id)
      assert_equal [ @cap.capability_id ], result.map(&:capability_id).uniq
    end

    should "narrow to one category at category focus" do
      result = entries(focus: :category, category_id: @cat.category_id)
      assert_equal [ @cat.category_id ], result.map(&:category_id).uniq
    end
  end

  context "ordering" do
    should "return reverse-chronological entries" do
      append(Frameworks::Events::CapabilityUpdated, data: { capability_id: @cap.capability_id, name: "first" })
      append(Frameworks::Events::CapabilityArchived, data: { capability_id: @cap.capability_id, reason: "second" })

      kinds = entries.map(&:kind)
      assert_operator kinds.index("capability_archived"), :<, kinds.index("capability_updated"),
        "most recent (archived) should come first"
    end
  end

  context "limit" do
    should "cap to the most-recent N entries when given a limit" do
      append(Frameworks::Events::CapabilityUpdated, data: { capability_id: @cap.capability_id, name: "first" })
      append(Frameworks::Events::CapabilityArchived, data: { capability_id: @cap.capability_id, reason: "second" })

      result = entries(limit: 1)
      assert_equal 1, result.size
      assert_equal "capability_archived", result.first.kind, "the single entry is the most recent"
    end
  end

  context "read cap" do
    should "read only the most-recent STREAM_READ_LIMIT events (older activity drops off)" do
      cap = Frameworks::ActivityFeedQuery::STREAM_READ_LIMIT

      # Oldest event first, then enough newer ones to push it past the cap.
      events = [ Frameworks::Events::CapabilityAdded.new(
        data: { framework_id: @fwid, capability_id: SecureRandom.uuid_v7, name: "OLDEST" },
        metadata: { tenant_id: @tenant.id }
      ) ]
      (cap + 5).times do
        events << Frameworks::Events::CapabilityAdded.new(
          data: { framework_id: @fwid, capability_id: SecureRandom.uuid_v7, name: "newer" },
          metadata: { tenant_id: @tenant.id }
        )
      end
      # append (not publish) writes raw events without dispatching the
      # synchronous projection — we're exercising the read query, not the
      # write side, and the minimal payloads aren't valid for the projection.
      Rails.configuration.event_store.append(events, stream_name: EventStreamNaming.framework_stream(@fwid))

      result = entries
      assert_operator result.size, :<=, cap, "feed must not exceed the read cap"
      assert_nil result.find { |e| e.payload[:name] == "OLDEST" },
        "an event older than the read cap must not appear in the feed"
    end

    should "report has_more + a cursor, and the next batch returns older, non-overlapping entries" do
      cap = Frameworks::ActivityFeedQuery::STREAM_READ_LIMIT
      events = Array.new(cap + 3) do |i|
        Frameworks::Events::CapabilityAdded.new(
          data: { framework_id: @fwid, capability_id: SecureRandom.uuid_v7, name: "cap-#{i}" },
          metadata: { tenant_id: @tenant.id }
        )
      end
      Rails.configuration.event_store.append(events, stream_name: EventStreamNaming.framework_stream(@fwid))

      first_q = Frameworks::ActivityFeedQuery.new(framework: @framework)
      first = first_q.call
      assert first_q.has_more?, "first batch should report more remaining"
      assert first_q.next_cursor.present?, "first batch should expose a cursor"

      second = Frameworks::ActivityFeedQuery.new(framework: @framework, before: first_q.next_cursor).call
      assert second.any?, "the next batch should return older entries"
      assert_empty(first.map(&:id) & second.map(&:id), "batches must not overlap")
    end
  end
end
