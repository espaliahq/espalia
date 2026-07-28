# frozen_string_literal: true

require "test_helper"

class Reporting::CycleCohortTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7

    @role = create(:framework_role, name: "Software Engineer")
    category = create(:framework_capability_category, framework_id: @framework_id)
    # Three active capabilities bound to the role → completion denominator of 3.
    @caps = Array.new(3) do
      cap = create(:framework_capability, category_id: category.category_id)
      create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: @role.role_id)
      cap
    end

    @cycle = create(:assessment_cycle,
      tenant: @tenant, framework_id: @framework_id, status: "open",
      planned_end_at: 1.month.from_now.to_date)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "#call funnel and status" do
    setup do
      # A: fully self-rated at the assessed level → self-done, not manager-done.
      @a = create(:person, tenant: @tenant, name: "Ada")
      enroll(@a)
      progress(@a, status: "started")
      @caps.each { |cap| rate(@a, cap, self_rated_frequency: "consistent") }

      # B: aligned (the explicit milestone).
      @b = create(:person, tenant: @tenant, name: "Bo")
      enroll(@b)
      create(:assessment_cycle_progress, :aligned, tenant: @tenant, cycle: @cycle, person_id: @b.id)

      # C: idle for 20 days → at-risk.
      @c = create(:person, tenant: @tenant, name: "Cy")
      enroll(@c, enrolled_at: 20.days.ago)
      progress(@c, status: "started", started_at: 20.days.ago)
    end

    should "count active participants" do
      assert_equal 3, result.total
    end

    should "build the self/manager/aligned funnel as head counts" do
      funnel = result.funnel
      assert_equal 3, funnel.enrolled
      assert_equal 1, funnel.self_done
      assert_equal 0, funnel.manager_done
      assert_equal 1, funnel.aligned
    end

    should "tally lifecycle status counts" do
      assert_equal({ "started" => 2, "aligned" => 1 }, result.status_counts)
    end

    should "flag the idle participant as at-risk" do
      assert_equal 1, result.at_risk_count
    end

    should "group by role and level in full mode" do
      assert_equal 1, result.groups[:role].size
      assert_equal 3, result.groups[:role].first.total
      assert_equal 1, result.groups[:level].size
    end

    should "scope to a subset of people" do
      scoped = Reporting::CycleCohort.new(cycle: @cycle, scope_person_ids: [ @a.id ]).call
      assert_equal 1, scoped.total
      assert_equal 1, scoped.funnel.self_done
    end

    should "omit participants and groups in summary mode but keep the funnel" do
      summary = Reporting::CycleCohort.new(cycle: @cycle, mode: :summary).call
      assert_empty summary.participants
      assert_empty summary.groups
      assert_equal 3, summary.funnel.enrolled
      assert_not_nil summary.top_lagging_group
    end
  end

  context "completion semantics" do
    should "not count carried (seeded) sides in the funnel — vetted only" do
      person = create(:person, tenant: @tenant, name: "Carried")
      enroll(person)
      @caps.each do |cap|
        rate(person, cap,
          self_rated_frequency: "consistent", self_rating_source: "seeded",
          manager_rated_frequency: "consistent", manager_rating_source: "seeded")
      end

      assert_equal 0, result.funnel.self_done,
        "a fully-carried self side is To confirm, not done"
      assert_equal 0, result.funnel.manager_done
    end

    should "count a side once its carried values are confirmed" do
      person = create(:person, tenant: @tenant, name: "Confirmed")
      enroll(person)
      @caps.each do |cap|
        rate(person, cap, self_rated_frequency: "consistent", self_rating_source: "human")
      end

      assert_equal 1, result.funnel.self_done
    end

    should "not count self-done when rated at a level other than the assessed level" do
      person = create(:person, tenant: @tenant, name: "Off-level")
      enroll(person, ordinal: 2)
      @caps.each { |cap| rate(person, cap, ordinal: 5, self_rated_frequency: "consistent") }

      assert_equal 0, result.funnel.self_done
    end

    should "count manager-done when every bound capability has a manager rating" do
      person = create(:person, tenant: @tenant, name: "Managed")
      enroll(person)
      @caps.each { |cap| rate(person, cap, manager_rated_frequency: "consistent") }

      assert_equal 1, result.funnel.manager_done
    end

    should "not count self-done when only some capabilities are rated" do
      person = create(:person, tenant: @tenant, name: "Partial")
      enroll(person)
      rate(person, @caps.first, self_rated_frequency: "consistent")

      assert_equal 0, result.funnel.self_done
    end
  end

  context "closed cycle" do
    should "keep concluded participants in the cohort, excluding only the withdrawn" do
      closed_cycle = create(:assessment_cycle,
        tenant: @tenant, framework_id: SecureRandom.uuid_v7, status: "closed")
      concluded = create(:person, tenant: @tenant, name: "Finished")
      create(:assessment_cycle_enrollment, :concluded,
        tenant: @tenant, cycle: closed_cycle, person_id: concluded.id,
        role_id: @role.role_id, level_ordinal: 2)
      withdrawn = create(:person, tenant: @tenant, name: "Removed")
      create(:assessment_cycle_enrollment, :withdrawn,
        tenant: @tenant, cycle: closed_cycle, person_id: withdrawn.id,
        role_id: @role.role_id, level_ordinal: 2)

      result = Reporting::CycleCohort.new(cycle: closed_cycle).call
      assert_equal 1, result.total
      assert_equal [ concluded.id ], result.participants.map(&:person_id)
    end

    should "never flag closed-cycle participants as at risk" do
      closed_cycle = create(:assessment_cycle,
        tenant: @tenant, framework_id: SecureRandom.uuid_v7, status: "closed",
        planned_end_at: 3.months.ago.to_date)
      person = create(:person, tenant: @tenant, name: "Unfinished")
      create(:assessment_cycle_enrollment, :concluded,
        tenant: @tenant, cycle: closed_cycle, person_id: person.id,
        role_id: @role.role_id, level_ordinal: 2, enrolled_at: 4.months.ago)
      create(:assessment_cycle_progress,
        tenant: @tenant, cycle: closed_cycle, person_id: person.id,
        status: "started", started_at: 4.months.ago)

      result = Reporting::CycleCohort.new(cycle: closed_cycle).call
      assert_equal 0, result.at_risk_count
    end
  end

  context "at-risk by deadline" do
    should "flag a non-aligned participant past the planned end date even if recently active" do
      # Its own framework_id — the tenant allows only one open cycle per
      # framework. Role bindings are role-scoped, so completion still resolves.
      overdue_cycle = create(:assessment_cycle,
        tenant: @tenant, framework_id: SecureRandom.uuid_v7, status: "open",
        planned_end_at: 3.days.ago.to_date)
      person = create(:person, tenant: @tenant, name: "Late")
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: overdue_cycle, person_id: person.id,
        role_id: @role.role_id, level_ordinal: 2, status: "enrolled")
      create(:assessment_cycle_progress,
        tenant: @tenant, cycle: overdue_cycle, person_id: person.id,
        status: "started", started_at: Time.current)

      result = Reporting::CycleCohort.new(cycle: overdue_cycle).call
      assert_equal 1, result.at_risk_count
    end
  end

  private

  def result
    @result ||= Reporting::CycleCohort.new(cycle: @cycle).call
  end

  def enroll(person, ordinal: 2, enrolled_at: Time.current)
    create(:assessment_cycle_enrollment,
      tenant: @tenant, cycle: @cycle, person_id: person.id,
      role_id: @role.role_id, level_ordinal: ordinal, status: "enrolled", enrolled_at: enrolled_at)
  end

  def progress(person, status:, started_at: Time.current)
    create(:assessment_cycle_progress,
      tenant: @tenant, cycle: @cycle, person_id: person.id, status: status, started_at: started_at)
  end

  def rate(person, capability, ordinal: 2, **frequencies)
    create(:assessment_level_rating,
      tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: person.id,
      framework_id: @framework_id, capability_stable_id: capability.stable_id,
      level_ordinal: ordinal, last_self_rated_at: Time.current, **frequencies)
  end
end
