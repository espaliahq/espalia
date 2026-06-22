# frozen_string_literal: true

require "test_helper"

class Home::RegistryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @person = create(:person, tenant: @tenant, name: "Viewer")
    @context = AuthorizationContext.new(user: build(:user), tenant_user: nil, person: @person)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  # Create a pending evidence request row directly (no factory exists).
  def pending_request!(requestee: @person, requester: @person, assessee: @person)
    EvidenceRequest.create!(
      id: SecureRandom.uuid_v7, tenant: @tenant, person_id: assessee.id,
      framework_id: SecureRandom.uuid_v7, requested_by_id: requester.id,
      requestee_person_id: requestee.id, capability_stable_id: SecureRandom.uuid_v7,
      level_ordinal: 2, status: "pending", requested_at: Time.current
    )
  end

  context ".find" do
    should "resolve a card class by key and return nil for unknown" do
      assert_equal Home::AssessmentProgressCard, Home::Registry.find("assessment_progress")
      assert_equal Home::AwaitingYouCard, Home::Registry.find("awaiting_you")
      assert_nil Home::Registry.find("nope")
    end
  end

  context ".instances_for" do
    should "return no instances when nothing is relevant" do
      assert_empty Home::Registry.instances_for(@context)
    end

    should "emit one assessment-progress instance per open cycle (multi-instance)" do
      cycle_a = create(:assessment_cycle, tenant: @tenant, name: "Alpha", status: "open")
      cycle_b = create(:assessment_cycle, tenant: @tenant, name: "Beta", status: "open")
      [ cycle_a, cycle_b ].each do |cycle|
        create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: cycle, person_id: @person.id, status: "enrolled")
      end

      instances = Home::Registry.instances_for(@context)
      progress = instances.select { |i| i.card_key == "assessment_progress" }

      assert_equal 2, progress.size
      assert_equal %w[Alpha Beta], progress.map(&:title).sort
    end

    should "order cards by descending priority (awaiting-you above own progress)" do
      cycle = create(:assessment_cycle, tenant: @tenant, name: "Q1", status: "open")
      # Viewer is an assessee...
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: cycle, person_id: @person.id, status: "enrolled")
      # ...and a manager with a pending report.
      report = create(:person, tenant: @tenant, name: "Report", manager: @person)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: cycle, person_id: report.id, status: "enrolled")
      create(:assessment_cycle_progress,
        tenant: @tenant, cycle: cycle, person_id: report.id, status: "started")

      keys = Home::Registry.instances_for(@context).map(&:card_key)

      assert_equal "awaiting_you", keys.first
      assert_includes keys, "assessment_progress"
    end

    should "exclude withdrawn enrollments from assessment-progress" do
      cycle = create(:assessment_cycle, tenant: @tenant, name: "Gone", status: "open")
      create(:assessment_cycle_enrollment, :withdrawn,
        tenant: @tenant, cycle: cycle, person_id: @person.id)

      assert_empty Home::Registry.instances_for(@context)
    end

    should "exclude closed cycles from assessment-progress" do
      cycle = create(:assessment_cycle, :closed, tenant: @tenant, name: "Closed")
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: cycle, person_id: @person.id, status: "enrolled")

      assert_empty Home::Registry.instances_for(@context)
    end
  end

  context "cycle-progress card audience" do
    setup do
      @cycle = create(:assessment_cycle, tenant: @tenant, name: "Q1", status: "open")
    end

    should "be hidden for a manager with no reports in any cycle" do
      assert_not Home::CycleProgressCard.audience?(@context)
    end

    should "be visible for a manager with a report enrolled, scoped to their subtree" do
      report = create(:person, tenant: @tenant, manager: @person)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: report.id, status: "enrolled")

      assert Home::CycleProgressCard.audience?(@context)
      keys = Home::CycleProgressCard.instances(@context).map(&:instance_key)
      assert_equal [ @cycle.cycle_id ], keys
    end

    should "be visible for an admin across all open cycles" do
      admin_tu = create(:tenant_user, tenant: @tenant, role: :admin)
      admin_ctx = AuthorizationContext.new(user: admin_tu.user, tenant_user: admin_tu, person: nil)

      assert Home::CycleProgressCard.audience?(admin_ctx)
    end
  end

  context "evidence-requests card" do
    should "be hidden when no one has asked the viewer for evidence" do
      assert_not Home::EvidenceRequestsCard.audience?(@context)
      assert_empty Home::EvidenceRequestsCard.instances(@context)
    end

    should "surface a single instance for a viewer with a pending incoming request" do
      asker = create(:person, tenant: @tenant, name: "Asker")
      pending_request!(requestee: @person, requester: asker, assessee: asker)

      assert Home::EvidenceRequestsCard.audience?(@context)
      instances = Home::EvidenceRequestsCard.instances(@context)
      assert_equal [ "evidence_requests" ], instances.map(&:card_key)
    end

    should "ignore non-pending and outgoing requests" do
      # Outgoing (viewer is the requester, someone else the requestee).
      other = create(:person, tenant: @tenant, name: "Other")
      pending_request!(requestee: other, requester: @person, assessee: @person)
      # Incoming but already answered.
      answered = pending_request!(requestee: @person, requester: other, assessee: other)
      answered.update!(status: "responded")

      assert_not Home::EvidenceRequestsCard.audience?(@context)
    end
  end

  context "recent-activity card" do
    should "be hidden when there is no activity" do
      assert_not Home::RecentActivityCard.audience?(@context)
    end

    should "show an IC their own activity" do
      cycle = create(:assessment_cycle, tenant: @tenant, status: "open")
      create(:assessment_level_rating,
        tenant: @tenant, cycle_id: cycle.cycle_id, person_id: @person.id,
        framework_id: cycle.framework_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, self_rated_frequency: "consistent", last_self_rated_at: Time.current)

      assert_equal [ @person.id ], Home::RecentActivityCard.scope_person_ids(@context)
      assert Home::RecentActivityCard.audience?(@context)
      assert_equal [ "recent_activity" ], Home::RecentActivityCard.instances(@context).map(&:card_key)
    end

    should "scope a manager to their direct reports' activity" do
      report = create(:person, tenant: @tenant, manager: @person)
      create(:evidence_item,
        tenant: @tenant, person_id: report.id, framework_id: SecureRandom.uuid_v7,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, recorded_at: Time.current)

      assert_equal [ report.id ], Home::RecentActivityCard.scope_person_ids(@context)
      assert Home::RecentActivityCard.audience?(@context)
    end
  end
end
