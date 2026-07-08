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

    should "flag the original edit as superseded once amended, leaving the amendment live" do
      append(Frameworks::Events::EditSuggested,
        data: { suggestion_id: @suggestion_id, target_entity_type: "capability",
                target_entity_id: @cap.capability_id, field: "description",
                suggested_value: "First", author_id: @actor.id },
        actor_id: @actor.id)
      append(Frameworks::Events::SuggestionAmended,
        data: { suggestion_id: @suggestion_id, new_suggested_value: "Second", author_id: @actor.id },
        actor_id: @actor.id)

      edit = entries.find { |e| e.kind == "suggestion_edit" }
      amended = entries.find { |e| e.kind == "suggestion_amended" }
      assert edit, "expected the original edit entry"
      assert amended, "expected the amendment entry"
      assert edit.superseded, "the original edit must be flagged superseded once amended"
      assert_not amended.superseded, "the latest amendment is the live, actionable proposal"
    end

    should "leave a lone (un-amended) edit un-superseded" do
      append(Frameworks::Events::EditSuggested,
        data: { suggestion_id: @suggestion_id, target_entity_type: "capability",
                target_entity_id: @cap.capability_id, field: "description",
                suggested_value: "Only", author_id: @actor.id },
        actor_id: @actor.id)

      edit = entries.find { |e| e.kind == "suggestion_edit" }
      assert_not edit.superseded
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

    should "emit a suggestion_commented entry anchored via the suggestion, under the suggestions group" do
      comment_id = SecureRandom.uuid_v7
      append(Frameworks::Events::SuggestionCommented,
        data: { suggestion_id: @suggestion_id, comment_id: comment_id,
                parent_id: nil, body: "Is this the right frame?", author_id: @reviewer.id },
        actor_id: @reviewer.id)
      # The synchronous projection always materialises the row in the live
      # flow; the entry body overlays the read model's current text.
      FrameworkState::SuggestionComment.create!(
        id: comment_id, tenant: @tenant, framework_id: @fwid,
        suggestion_id: @suggestion_id, author_id: @reviewer.id,
        body: "Is this the right frame?", status: "active", posted_at: Time.current
      )

      entry = entries.find { |e| e.kind == "suggestion_commented" }
      assert entry, "expected a suggestion_commented entry"
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal @suggestion_id, entry.suggestion_id
      assert_equal "Rita Reviewer", entry.actor_name
      assert_equal "Is this the right frame?", entry.payload[:body]
      assert_equal "suggestions", Views::Frameworks::Activity::Entry::KIND_GROUP.fetch("suggestion_commented")
      assert_not_nil Views::Frameworks::Activity::Entry::KIND_DOT["suggestion_commented"]
    end

    should "render the read model's current body on comment entries — deleted bodies disappear" do
      deleted_id = SecureRandom.uuid_v7
      edited_id = SecureRandom.uuid_v7
      append(Frameworks::Events::SuggestionCommented,
        data: { suggestion_id: @suggestion_id, comment_id: deleted_id,
                parent_id: nil, body: "Sensitive — please remove", author_id: @actor.id },
        actor_id: @actor.id)
      append(Frameworks::Events::SuggestionCommented,
        data: { suggestion_id: @suggestion_id, comment_id: edited_id,
                parent_id: nil, body: "Original wording", author_id: @actor.id },
        actor_id: @actor.id)
      # Read model state: first comment deleted, second edited.
      FrameworkState::SuggestionComment.create!(
        id: deleted_id, tenant: @tenant, framework_id: @fwid,
        suggestion_id: @suggestion_id, author_id: @actor.id,
        body: "Sensitive — please remove", status: "deleted", posted_at: 2.minutes.ago
      )
      FrameworkState::SuggestionComment.create!(
        id: edited_id, tenant: @tenant, framework_id: @fwid,
        suggestion_id: @suggestion_id, author_id: @actor.id,
        body: "Revised wording", status: "active", posted_at: 1.minute.ago
      )

      comment_entries = entries.select { |e| e.kind == "suggestion_commented" }
      bodies = comment_entries.to_h { |e| [ e.payload[:comment_id], e.payload[:body] ] }
      assert_nil bodies[deleted_id], "a deleted comment's body must not linger in the feed"
      assert_equal "Revised wording", bodies[edited_id], "the feed shows the current, not original, body"
    end

    should "overlay comment count + latest excerpt on suggestion-anchored entries" do
      append(Frameworks::Events::EditSuggested,
        data: { suggestion_id: @suggestion_id, target_entity_type: "capability",
                target_entity_id: @cap.capability_id, field: "description",
                suggested_value: "Better text", author_id: @actor.id },
        actor_id: @actor.id)

      FrameworkState::SuggestionComment.create!(
        id: SecureRandom.uuid_v7, tenant: @tenant, framework_id: @fwid,
        suggestion_id: @suggestion_id, author_id: @reviewer.id,
        body: "First take", status: "active", posted_at: 2.minutes.ago
      )
      FrameworkState::SuggestionComment.create!(
        id: SecureRandom.uuid_v7, tenant: @tenant, framework_id: @fwid,
        suggestion_id: @suggestion_id, author_id: @actor.id,
        body: "Latest word", status: "active", posted_at: 1.minute.ago
      )
      # Deleted comments never count toward the affordance.
      FrameworkState::SuggestionComment.create!(
        id: SecureRandom.uuid_v7, tenant: @tenant, framework_id: @fwid,
        suggestion_id: @suggestion_id, author_id: @actor.id,
        body: "Gone", status: "deleted", posted_at: Time.current
      )

      entry = entries.find { |e| e.kind == "suggestion_edit" }
      assert_equal 2, entry.comment_count
      assert_equal "Latest word", entry.latest_comment
    end
  end

  context "suggestion create lifecycle" do
    setup do
      @create_sid = SecureRandom.uuid_v7
      create(:framework_suggested_edit,
        tenant: @tenant, framework_id: @fwid, suggestion_id: @create_sid,
        target_entity_type: "behavioural_expectation", target_entity_id: nil,
        parent_id: @cap.capability_id, kind: "create", author_id: @actor.id,
        proposed_attributes: { "level_ordinal" => 2, "description" => "Anticipates risks" })
    end

    should "carry proposed_attributes so the feed can preview the proposed value" do
      append(Frameworks::Events::EntityCreationSuggested,
        data: { suggestion_id: @create_sid, target_entity_type: "behavioural_expectation",
                parent_id: @cap.capability_id, author_id: @actor.id,
                proposed_attributes: { "level_ordinal" => 2, "description" => "Anticipates risks" } },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "suggestion_create" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal "Anticipates risks", entry.payload[:proposed_attributes]["description"]
    end

    should "flag the original create as superseded once amended, leaving the amendment live" do
      append(Frameworks::Events::EntityCreationSuggested,
        data: { suggestion_id: @create_sid, target_entity_type: "behavioural_expectation",
                parent_id: @cap.capability_id, author_id: @actor.id,
                proposed_attributes: { "level_ordinal" => 2, "description" => "First" } },
        actor_id: @actor.id)
      append(Frameworks::Events::SuggestionAmended,
        data: { suggestion_id: @create_sid, new_suggested_value: "Second", author_id: @actor.id },
        actor_id: @actor.id)

      created = entries.find { |e| e.kind == "suggestion_create" }
      amended = entries.find { |e| e.kind == "suggestion_amended" }
      assert created.superseded, "the original create is superseded by the amendment"
      assert_not amended.superseded, "the amendment stays live"
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

    should "anchor an expectation_added to its capability with the level + description" do
      append(Frameworks::Events::BehaviouralExpectationSet,
        data: { expectation_id: SecureRandom.uuid_v7, stable_id: SecureRandom.uuid_v7,
                capability_id: @cap.capability_id, level_ordinal: 3, description: "Identifies root causes" },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "expectation_added" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "Ada Author", entry.actor_name
      assert_equal "structural", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
      assert_equal 3, entry.payload[:level_ordinal]
      assert_equal "Identifies root causes", entry.payload[:description]
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

  context "org-structure renames" do
    should "emit a framework-level role_family_updated entry in the edits group" do
      append(Frameworks::Events::RoleFamilyUpdated,
        data: { role_family_id: SecureRandom.uuid_v7, name: "Platform Engineering" },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "role_family_updated" }
      assert entry
      assert_nil entry.capability_id, "org-structure renames carry no matrix anchor"
      assert_nil entry.category_id
      assert_equal "Ada Author", entry.actor_name
      assert_equal "Platform Engineering", entry.payload[:name]
      assert_equal "edits", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
    end

    should "emit a framework-level role_updated entry in the edits group" do
      append(Frameworks::Events::RoleUpdated,
        data: { role_id: SecureRandom.uuid_v7, name: "Backend Engineer" })

      entry = entries.find { |e| e.kind == "role_updated" }
      assert entry
      assert_nil entry.capability_id
      assert_equal "Backend Engineer", entry.payload[:name]
      assert_equal "edits", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
    end

    should "emit a framework-level level_updated entry in the edits group" do
      append(Frameworks::Events::LevelUpdated,
        data: { level_id: SecureRandom.uuid_v7, title: "Engineer One" })

      entry = entries.find { |e| e.kind == "level_updated" }
      assert entry
      assert_nil entry.capability_id
      assert_equal "Engineer One", entry.payload[:title]
      assert_equal "edits", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
    end
  end

  context "org-structure adds" do
    should "emit a framework-level role_family_added entry in the structural group" do
      append(Frameworks::Events::RoleFamilyAdded,
        data: { framework_id: @fwid, role_family_id: SecureRandom.uuid_v7,
                name: "Design", description: nil, department: "Product + Design" },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "role_family_added" }
      assert entry
      assert_nil entry.capability_id, "org-structure adds carry no matrix anchor"
      assert_nil entry.category_id
      assert_equal "Ada Author", entry.actor_name
      assert_equal "Design", entry.payload[:name]
      assert_equal "structural", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
    end

    should "emit a framework-level role_added entry in the structural group" do
      append(Frameworks::Events::RoleAdded,
        data: { framework_id: @fwid, role_id: SecureRandom.uuid_v7,
                role_family_id: SecureRandom.uuid_v7, name: "Engineering Manager",
                code: "EM", track: "management" })

      entry = entries.find { |e| e.kind == "role_added" }
      assert entry
      assert_nil entry.capability_id
      assert_equal "Engineering Manager", entry.payload[:name]
      assert_equal "EM", entry.payload[:code]
      assert_equal "structural", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
    end

    should "emit a framework-level level_added entry naming the role, in the structural group" do
      family = create(:framework_role_family, framework_id: @fwid, tenant: @tenant)
      role = create(:framework_role, role_family_id: family.role_family_id, tenant: @tenant,
        name: "Engineering Manager", code: "EM")
      append(Frameworks::Events::LevelAdded,
        data: { framework_id: @fwid, level_id: SecureRandom.uuid_v7, role_id: role.role_id,
                ordinal: 4, title: "Senior EM", code: "EM4", is_entry: false },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "level_added" }
      assert entry
      assert_nil entry.capability_id, "level adds carry no matrix anchor"
      assert_equal "EM · Engineering Manager", entry.payload[:level_role_label]
      assert_equal 4, entry.payload[:ordinal]
      assert_equal "Senior EM", entry.payload[:title]
      assert_equal "structural", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
    end
  end

  context "binding lifecycle" do
    setup do
      @role_family = create(:framework_role_family, framework_id: @fwid, tenant: @tenant)
      @role = create(:framework_role, role_family_id: @role_family.role_family_id, tenant: @tenant,
        name: "Engineering Manager", code: "EM")
    end

    should "anchor binding_added to its capability + category, with role + weight, actor from metadata" do
      append(Frameworks::Events::CapabilityRoleBindingCreated,
        data: { binding_id: SecureRandom.uuid_v7, capability_id: @cap.capability_id,
                role_id: @role.role_id, weight: 2.5, individual_tolerance: nil },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "binding_added" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "Ada Author", entry.actor_name
      assert_equal "structural", Views::Frameworks::Activity::Entry::KIND_GROUP[entry.kind]
      assert_equal "EM · Engineering Manager", entry.payload[:binding_role_label]
      assert_equal 2.5, entry.payload[:binding_weight].to_f
    end

    should "anchor binding_updated to the capability + role, surfacing the changed weight" do
      bid = SecureRandom.uuid_v7
      append(Frameworks::Events::CapabilityRoleBindingCreated,
        data: { binding_id: bid, capability_id: @cap.capability_id,
                role_id: @role.role_id, weight: 1.0 })
      append(Frameworks::Events::CapabilityRoleBindingUpdated,
        data: { binding_id: bid, weight: 2.0 }, actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "binding_updated" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "EM · Engineering Manager", entry.payload[:binding_role_label]
      assert_equal 2.0, entry.payload[:binding_weight].to_f
    end

    should "anchor binding_removed via the created event still in the window, naming the role" do
      bid = SecureRandom.uuid_v7
      append(Frameworks::Events::CapabilityRoleBindingCreated,
        data: { binding_id: bid, capability_id: @cap.capability_id,
                role_id: @role.role_id, weight: 1.0 })
      append(Frameworks::Events::CapabilityRoleBindingRemoved, data: { binding_id: bid })

      entry = entries.find { |e| e.kind == "binding_removed" }
      assert entry
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal "EM · Engineering Manager", entry.payload[:binding_role_label]
    end

    should "fall back to a framework-level anchor when the binding can't be resolved" do
      append(Frameworks::Events::CapabilityRoleBindingRemoved,
        data: { binding_id: SecureRandom.uuid_v7 })

      entry = entries.find { |e| e.kind == "binding_removed" }
      assert entry
      assert_nil entry.capability_id
      assert_nil entry.category_id
    end
  end

  # A draft-added capability/expectation isn't in the published read model yet,
  # but the feed must still name it (from the creating event in the window).
  context "draft-entity naming and expectation levels" do
    setup do
      @draft_cap_id = SecureRandom.uuid_v7
      @role = create(:framework_role, role_family_id: SecureRandom.uuid_v7, tenant: @tenant,
        name: "Engineering Manager", code: "EM")
    end

    should "name a draft-added capability from its CapabilityAdded event" do
      append(Frameworks::Events::CapabilityAdded,
        data: { capability_id: @draft_cap_id, stable_id: SecureRandom.uuid_v7,
                category_id: @cat.category_id, name: "Draft Capability" })

      entry = entries.find { |e| e.kind == "capability_added" }
      assert entry
      assert_equal @draft_cap_id, entry.capability_id
      assert_equal "Draft Capability", entry.capability_name
    end

    should "reflect a rename of a draft-added capability (newest name wins)" do
      append(Frameworks::Events::CapabilityAdded,
        data: { capability_id: @draft_cap_id, stable_id: SecureRandom.uuid_v7,
                category_id: @cat.category_id, name: "Original Draft Name" })
      append(Frameworks::Events::CapabilityUpdated,
        data: { capability_id: @draft_cap_id, name: "Renamed Draft" })

      entry = entries.find { |e| e.kind == "capability_added" }
      assert_equal "Renamed Draft", entry.capability_name
    end

    should "name the capability for a binding on a draft-added capability" do
      append(Frameworks::Events::CapabilityAdded,
        data: { capability_id: @draft_cap_id, stable_id: SecureRandom.uuid_v7,
                category_id: @cat.category_id, name: "Draft Capability" })
      append(Frameworks::Events::CapabilityRoleBindingCreated,
        data: { binding_id: SecureRandom.uuid_v7, capability_id: @draft_cap_id,
                role_id: @role.role_id, weight: 1.0 })

      entry = entries.find { |e| e.kind == "binding_added" }
      assert entry
      assert_equal @draft_cap_id, entry.capability_id
      assert_equal "Draft Capability", entry.capability_name
    end

    should "pin the level on a directly-authored expectation" do
      append(Frameworks::Events::BehaviouralExpectationSet,
        data: { expectation_id: SecureRandom.uuid_v7, stable_id: SecureRandom.uuid_v7,
                capability_id: @cap.capability_id, level_ordinal: 4, description: "X" })

      entry = entries.find { |e| e.kind == "expectation_added" }
      assert_equal 4, entry.payload[:expectation_level]
    end

    should "pin the level on a proposed (create) expectation suggestion" do
      sid = SecureRandom.uuid_v7
      create(:framework_suggested_edit, tenant: @tenant, framework_id: @fwid, suggestion_id: sid,
        target_entity_type: "behavioural_expectation", target_entity_id: nil, parent_id: @cap.capability_id,
        kind: "create", author_id: @actor.id, proposed_attributes: { "level_ordinal" => 5, "description" => "Y" })
      append(Frameworks::Events::EntityCreationSuggested,
        data: { suggestion_id: sid, target_entity_type: "behavioural_expectation", parent_id: @cap.capability_id,
                author_id: @actor.id, proposed_attributes: { "level_ordinal" => 5, "description" => "Y" } },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "suggestion_create" }
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal 5, entry.payload[:expectation_level]
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
  context "capability reorder" do
    should "emit a category-anchored capability_reordered entry (structural group)" do
      append(Frameworks::Events::CapabilityReordered,
        data: { category_id: @cat.category_id, new_ordering: [ @cap.capability_id ] },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "capability_reordered" }
      assert_not_nil entry, "expected a capability_reordered entry"
      assert_nil entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "structural", Views::Frameworks::Activity::Entry::KIND_GROUP.fetch(entry.kind)

      # Anchored at the category: visible under that category's focus, hidden
      # under the other category's.
      assert entries(focus: :category, category_id: @cat.category_id)
        .any? { |e| e.kind == "capability_reordered" }
      assert_not entries(focus: :category, category_id: @other_cat.category_id)
        .any? { |e| e.kind == "capability_reordered" }
    end
  end

  context "category reorder" do
    should "emit a framework-level category_reordered entry (structural group)" do
      append(Frameworks::Events::CapabilityCategoryReordered,
        data: { new_ordering: [ @other_cat.category_id, @cat.category_id ] },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "category_reordered" }
      assert_not_nil entry, "expected a category_reordered entry"
      assert_nil entry.capability_id
      assert_nil entry.category_id
      assert_equal "structural", Views::Frameworks::Activity::Entry::KIND_GROUP.fetch(entry.kind)

      # Framework-level: hidden under a narrower focus.
      focused = entries(focus: :capability, capability_id: @cap.capability_id)
      assert_not focused.any? { |e| e.kind == "category_reordered" }
    end
  end

  context "illustration reorder" do
    setup do
      @family = create(:framework_role_family, framework_id: @fwid, tenant: @tenant)
      @role = create(:framework_role, role_family_id: @family.role_family_id,
        tenant: @tenant, name: "Software Engineer", code: "E")
    end

    should "emit an illustration_reordered entry anchored to the capability, naming the role" do
      append(Frameworks::Events::RoleIllustrationReordered,
        data: { expectation_id: @exp.expectation_id, role_id: @role.role_id,
                new_ordering: [ @ill.illustration_id ] },
        actor_id: @actor.id)

      entry = entries.find { |e| e.kind == "illustration_reordered" }
      assert_not_nil entry, "expected an illustration_reordered entry"
      assert_equal @cap.capability_id, entry.capability_id
      assert_equal @cat.category_id, entry.category_id
      assert_equal "E · Software Engineer", entry.payload[:reorder_role_label]
      assert_equal "edits", Views::Frameworks::Activity::Entry::KIND_GROUP.fetch(entry.kind)
    end

    should "narrow to the capability under capability focus" do
      append(Frameworks::Events::RoleIllustrationReordered,
        data: { expectation_id: @exp.expectation_id, role_id: @role.role_id,
                new_ordering: [ @ill.illustration_id ] })

      focused = entries(focus: :capability, capability_id: @cap.capability_id)
      assert focused.any? { |e| e.kind == "illustration_reordered" }

      elsewhere = entries(focus: :capability, capability_id: @other_cap.capability_id)
      assert_not elsewhere.any? { |e| e.kind == "illustration_reordered" }
    end
  end
end
