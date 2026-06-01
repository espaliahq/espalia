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
end
