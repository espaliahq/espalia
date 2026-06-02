# frozen_string_literal: true

require "test_helper"

class Assessments::RecentActivityQueryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7

    category = create(:framework_capability_category, framework_id: @framework_id)
    @cap = create(:framework_capability, category_id: category.category_id, name: "Strategic Thinking")

    @assessee = create(:person, tenant: @tenant, name: "Ada")
    @manager = create(:person, tenant: @tenant, name: "Boss", manager: nil)
    @assessee.update!(manager: @manager)
    @assignment = create(:person_framework_assignment,
      tenant: @tenant, person_id: @assessee.id, framework_id: @framework_id)

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, status: "open")

    # Distinct timestamps so ordering is deterministic (newest first).
    create(:assessment_level_rating,
      tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @assessee.id, framework_id: @framework_id,
      capability_stable_id: @cap.stable_id, level_ordinal: 2,
      manager_rated_frequency: "consistent", last_manager_rated_at: 4.minutes.ago,
      manager_rated_by_id: @manager.id)
    create(:evidence_item,
      tenant: @tenant, person_id: @assessee.id, framework_id: @framework_id,
      capability_stable_id: @cap.stable_id, level_ordinal: 2, recorded_at: 3.minutes.ago)
    create(:person_development_comment,
      tenant: @tenant, person_id: @assessee.id, framework_id: @framework_id,
      capability_stable_id: @cap.stable_id, level_ordinal: 2, posted_at: 2.minutes.ago)
    create(:assessment_cycle_progress, :aligning,
      tenant: @tenant, cycle: @cycle, person_id: @assessee.id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def items(person_ids: [ @assessee.id ], **opts)
    Assessments::RecentActivityQuery.new(person_ids: person_ids, **opts).call
  end

  context "#call" do
    should "merge activity across sources, most-recent first" do
      kinds = items.map(&:kind)
      assert_includes kinds, "manager_rated"
      assert_includes kinds, "evidence_recorded"
      assert_includes kinds, "comment_posted"
      assert_includes kinds, "alignment_started"
      # alignment_started (just now via :aligning trait) is the most recent.
      assert_equal "alignment_started", kinds.first
      occurred = items.map(&:occurred_at)
      assert_equal occurred.sort.reverse, occurred
    end

    should "resolve assessee name, assignment id, and capability name" do
      manager_item = items.find { |i| i.kind == "manager_rated" }
      assert_equal "Ada", manager_item.person_name
      assert_equal @assignment.id, manager_item.assignment_id
      assert_equal "Strategic Thinking", manager_item.capability_name
      assert_equal 2, manager_item.level_ordinal
    end

    should "attribute the manager rating to the manager (actor differs from assessee)" do
      manager_item = items.find { |i| i.kind == "manager_rated" }
      assert_equal @manager.id, manager_item.actor_id
      assert_equal "Boss", manager_item.actor_name
      assert manager_item.actor_other?
    end

    should "respect the limit" do
      assert_equal 2, items(limit: 2).size
    end

    should "return nothing for people with no activity" do
      other = create(:person, tenant: @tenant, name: "Nobody")
      assert_empty items(person_ids: [ other.id ])
    end

    should "return nothing for an empty scope" do
      assert_empty items(person_ids: [])
    end
  end

  context "#any?" do
    should "be true when activity exists and false otherwise" do
      assert Assessments::RecentActivityQuery.new(person_ids: [ @assessee.id ]).any?
      other = create(:person, tenant: @tenant, name: "Nobody")
      assert_not Assessments::RecentActivityQuery.new(person_ids: [ other.id ]).any?
      assert_not Assessments::RecentActivityQuery.new(person_ids: []).any?
    end
  end
end
