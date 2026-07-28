# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::PopulationSeedsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em_1 = create(:person, tenant: @tenant, name: "Mia", manager: @dept_head)
    @em_2 = create(:person, tenant: @tenant, name: "Raj", manager: @dept_head)
    @report_1 = create(:person, tenant: @tenant, name: "Ivy", manager: @em_1)
    @report_2 = create(:person, tenant: @tenant, name: "Omar", manager: @em_2)

    [ @em_1, @em_2, @report_1, @report_2 ].each { |p| assign(p) }
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def assign(person)
    create(:person_framework_assignment, tenant: @tenant,
           person_id: person.id, framework_id: @framework_id)
  end

  def seeds(participant_ids: [ @em_1.id, @em_2.id ], facilitator_id: @dept_head.id)
    CalibrationSessions::PopulationSeeds.new(
      framework_id: @framework_id,
      participant_ids: participant_ids,
      facilitator_id: facilitator_id
    )
  end

  context "live-manager fallback" do
    should "group each participant's live reports" do
      result = seeds.call

      assert_equal [ @report_1.id ], result[@em_1.id].map(&:id)
      assert_equal [ @report_2.id ], result[@em_2.id].map(&:id)
    end

    should "exclude participants and the facilitator from every group" do
      # em_2 also reports to dept_head, but as a participant they never seed
      result = seeds(participant_ids: [ @dept_head.id, @em_1.id ], facilitator_id: nil).call

      assert_equal [ @em_2.id ], result[@dept_head.id].map(&:id),
        "em_1 (a participant) is excluded from dept_head's group"
    end

    should "exclude people with no assignment on the framework" do
      unassigned = create(:person, tenant: @tenant, name: "New Norah", manager: @em_1)

      assert_not_includes seeds.person_ids, unassigned.id
    end
  end

  context "recorded reporting manager" do
    should "override the live manager, even when it points elsewhere" do
      # report_1 lives under em_1 in the org chart, but the recorded manager
      # (authoritative for rating) is em_2 — the seed follows the recording.
      create(:recorded_reporting_manager, tenant: @tenant,
             person_id: @report_1.id, framework_id: @framework_id, manager_id: @em_2.id)

      result = seeds.call
      assert_equal [], result[@em_1.id].map(&:id)
      assert_equal [ @report_1.id, @report_2.id ].sort, result[@em_2.id].map(&:id).sort
    end
  end

  context "delegations" do
    should "include an active delegation's report under the delegate" do
      seconded = create(:person, tenant: @tenant, name: "Sam Seconded")
      assign(seconded)
      create(:manager_assessment_delegation, tenant: @tenant,
             person_id: seconded.id, framework_id: @framework_id,
             delegate_person_id: @em_1.id)

      result = seeds.call
      assert_includes result[@em_1.id].map(&:id), seconded.id
    end
  end

  context "#person_ids" do
    should "return the flat deduplicated seed" do
      assert_equal [ @report_1.id, @report_2.id ].sort, seeds.person_ids.sort
    end
  end

  context "#attribution (dual-claimed person)" do
    setup do
      # report_1's recorded reporting manager is em_1 AND em_2 holds an
      # active rating delegation for them — both participants claim them.
      create(:recorded_reporting_manager, tenant: @tenant,
             person_id: @report_1.id, framework_id: @framework_id, manager_id: @em_1.id)
      create(:manager_assessment_delegation, tenant: @tenant,
             person_id: @report_1.id, framework_id: @framework_id,
             delegate_person_id: @em_2.id)
    end

    should "attribute to exactly one participant — first in participant order wins" do
      assert_equal @em_1.id, seeds.attribution[@report_1.id]
      assert_equal @em_2.id,
        seeds(participant_ids: [ @em_2.id, @em_1.id ]).attribution[@report_1.id],
        "the tiebreak is participant order, deterministically"
    end

    should "list the person under only one group in #call" do
      result = seeds.call
      assert_equal [ @report_1.id ], result[@em_1.id].map(&:id)
      assert_not_includes result[@em_2.id].map(&:id), @report_1.id,
        "a dual-claimed person must not render twice on the population card"
    end

    should "count the person once in #person_ids" do
      assert_equal 1, seeds.person_ids.count(@report_1.id)
    end
  end
end
