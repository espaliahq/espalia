# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::DrillInStatsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em_1 = create(:person, tenant: @tenant, name: "Mia", manager: @dept_head)
    @em_2 = create(:person, tenant: @tenant, name: "Raj", manager: @dept_head)
    @r1 = create(:person, tenant: @tenant, name: "Ivy", manager: @em_1)     # L3
    @r2 = create(:person, tenant: @tenant, name: "Omar", manager: @em_2)    # L4
    @other_manager = create(:person, tenant: @tenant, name: "Kim Elsewhere")
    @ref = create(:person, tenant: @tenant, name: "Ref Point", manager: @other_manager) # L3

    # The population is all engineers; the framework also carries an EM role
    # that nobody on this grid holds.
    @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer", code: "E")
    @manager_role = create(:framework_role, tenant: @tenant, name: "Engineering Manager", code: "EM")

    # Deliberately split by level: L3 is engineers, L4 is the manager. Only
    # a population whose LEVELS hold different roles exercises the
    # per-ordinal narrowing — with one role everywhere, the union `where`
    # already excludes everything and the narrowing is untested.
    { @r1 => [ 3, @engineer ], @ref => [ 3, @engineer ], @r2 => [ 4, @manager_role ] }
      .each do |person, (ordinal, role)|
        create(:person_framework_assignment, tenant: @tenant,
               person_id: person.id, framework_id: @framework_id, role_id: role.role_id)
        # role_id on the enrollment is the ADR-19 snapshot the drill-in reads.
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: person.id, level_ordinal: ordinal, role_id: role.role_id)
      end

    category = create(:framework_capability_category, tenant: @tenant,
                      framework_id: @framework_id, name: "Thinking")
    @cap = create(:framework_capability, tenant: @tenant,
                  category_id: category.category_id, name: "Strategic Thinking")
    [ @engineer, @manager_role ].each do |role|
      create(:framework_capability_role_binding, tenant: @tenant,
             capability_id: @cap.capability_id, role_id: role.role_id)
    end
    @exp_l3 = create(:framework_behavioural_expectation, tenant: @tenant,
                     capability_id: @cap.capability_id, level_ordinal: 3,
                     description: "Identifies root causes and weighs trade-offs.")
    create(:framework_behavioural_expectation, tenant: @tenant,
           capability_id: @cap.capability_id, level_ordinal: 4,
           description: "Shapes team direction by connecting work to strategy.")

    @session = create(:calibration_session, tenant: @tenant,
                      cycle_id: @cycle.cycle_id, framework_id: @framework_id,
                      facilitator_id: @dept_head.id, status: "started")
    [ @em_1, @em_2 ].each do |em|
      create(:calibration_session_member, :participant, tenant: @tenant,
             session: @session, person_id: em.id)
    end
    [ @r1, @r2, @ref ].each do |person|
      create(:calibration_session_member, tenant: @tenant,
             session: @session, person_id: person.id)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def stats(stable_id: @cap.stable_id)
    CalibrationSessions::DrillInStats.new(
      session: @session, capability_stable_id: stable_id
    ).call
  end

  def dot(result, person)
    result[:levels].values.flatten.find { |d| d[:person_id] == person.id }
  end

  should "return nil for a capability outside the framework" do
    assert_nil stats(stable_id: SecureRandom.uuid_v7)
  end

  should "carry the capability header and per-level expectation text" do
    result = stats
    assert_equal "Strategic Thinking", result[:capability][:name]
    assert_equal "Thinking", result[:capability][:category_name]
    assert_equal [ 3, 4 ], result[:ordinals]
    assert_match(/root causes/, result[:expectations][3])
    assert_match(/team direction/, result[:expectations][4])
  end

  should "place each member at their assessed level with their rater, rating + backing" do
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @r1.id, framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 3,
           manager_rated_frequency: "consistent", self_rated_frequency: "occasional")
    create(:evidence_item, tenant: @tenant, person_id: @r1.id,
           framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 3)

    result = stats
    ivy = result[:levels][3].find { |d| d[:person_id] == @r1.id }

    assert_equal "Ivy", ivy[:name]
    assert_equal @em_1.id, ivy[:rater_id]
    assert_equal "consistent", ivy[:frequency]
    assert_equal "occasional", ivy[:self_frequency]
    assert ivy[:backed]
    assert_equal [ @em_1.id, @em_2.id ], result[:rater_ids], "participants, in session order"
  end

  should "group each level's members by name, levels in order" do
    result = stats

    assert_equal [ 3, 4 ], result[:levels].keys
    assert_equal [ "Ivy", "Ref Point" ], result[:levels][3].map { |d| d[:name] }
    assert_equal [ "Omar" ], result[:levels][4].map { |d| d[:name] }
  end

  should "ignore ratings outside the assessed role" do
    rating = create_out_of_scope_rating(person_id: @r1.id, cycle: @cycle, level_ordinal: 3)

    assert_nil dot(stats(stable_id: rating.capability_stable_id), @r1)[:frequency]
  end

  should "render unrated members as frequency-nil dots" do
    omar = dot(stats, @r2)

    assert_equal "Omar", omar[:name]
    assert_equal @em_2.id, omar[:rater_id]
    assert_nil omar[:frequency]
    assert_not omar[:backed]
  end

  should "leave the rater nil for a member whose rater is not in the session" do
    assert_nil dot(stats, @ref)[:rater_id]
  end

  should "attribute through the request's PopulationSeeds when one is passed" do
    seeds = CalibrationSessions::PopulationSeeds.new(
      framework_id: @framework_id, participant_ids: [ @em_1.id, @em_2.id ],
      facilitator_id: @dept_head.id
    )
    result = CalibrationSessions::DrillInStats.new(
      session: @session, capability_stable_id: @cap.stable_id, population_seeds: seeds
    ).call

    assert_equal @em_1.id, dot(result, @r1)[:rater_id]
  end

  should "ignore ratings at a different level than the assessed one" do
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @r1.id, framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 5,
           manager_rated_frequency: "consistent")

    assert_nil dot(stats, @r1)[:frequency]
  end

  context "illustrations" do
    setup do
      illustrate(@engineer, "Unwinds a circular dependency without help.")
      illustrate(@manager_role, "Coaches the team through the trade-off.")
    end

    should "include only the roles being calibrated at that level" do
      groups = stats[:illustrations][3]

      assert_equal [ "Software Engineer" ], groups.map { |g| g[:role_name] }
      # Items carry their illustration_id so each example is flaggable.
      assert_equal [ "Unwinds a circular dependency without help." ],
                   groups.first[:items].map { |item| item[:text] }
      assert groups.first[:items].all? { |item| item[:id].present? }
    end

    should "include a role once the population holds it at that level" do
      # Enrol one L3 member AS a manager — the cycle snapshot is what says
      # which roles are being calibrated, so now both sets of examples are
      # relevant at L3.
      AssessmentCycleEnrollment
        .find_by(cycle_id: @cycle.cycle_id, person_id: @ref.id)
        .update!(role_id: @manager_role.role_id)

      assert_equal [ "Engineering Manager", "Software Engineer" ],
                   stats[:illustrations][3].map { |g| g[:role_name] }
    end

    should "read the cycle's role snapshot when the live assignment has moved on" do
      # The state a CLOSED cycle reaches: ParticipantRoleSync stops
      # re-snapshotting the enrollment, so a later HRIS PersonRoleChanged
      # moves the assignment row alone. A closed session is read for months
      # afterwards and must still show the examples for the role the ratings
      # were made against.
      @cycle.update!(status: "closed")
      PersonFrameworkAssignment
        .find_by(person_id: @r1.id, framework_id: @framework_id)
        .update!(role_id: @manager_role.role_id)

      assert_equal [ "Software Engineer" ], stats[:illustrations][3].map { |g| g[:role_name] },
        "a role change after the cycle closed must not rewrite the examples"
    end

    should "narrow per level, not just to the union of the grid's roles" do
      # The manager role IS calibrated — at L4 — so it survives the SQL
      # `where`. Only the per-ordinal narrowing keeps its L3 examples out of
      # L3, where nobody holds that role.
      assert_equal [ "Software Engineer" ], stats[:illustrations][3].map { |g| g[:role_name] },
        "manager examples must not leak into a level with no managers"
    end
  end

  def illustrate(role, description)
    create(:framework_role_illustration, tenant: @tenant,
           expectation_id: @exp_l3.expectation_id, role_id: role.role_id,
           description: description)
  end

  # @r1's dot, built with the given entitlement set (nil = ungated).
  def gated_dot(visible)
    CalibrationSessions::DrillInStats.new(
      session: @session, capability_stable_id: @cap.stable_id,
      visible_person_ids: visible
    ).call[:levels][3].find { |d| d[:person_id] == @r1.id }
  end

  context "assessee entitlement" do
    setup do
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
             person_id: @r1.id, framework_id: @framework_id,
             capability_stable_id: @cap.stable_id, level_ordinal: 3,
             manager_rated_frequency: "consistent", self_rated_frequency: "occasional")
    end

    should "withhold the self-rating outside the viewer's entitlement" do
      dot = gated_dot([ @r2.id ])

      assert dot[:self_withheld]
      assert_nil dot[:self_frequency], "the value must not reach the view at all"
      # The rater is in the room to defend this one — it is the session's subject.
      assert_equal "consistent", dot[:frequency]
    end

    should "keep it for someone inside the entitlement, and when ungated" do
      assert_equal "occasional", gated_dot([ @r1.id, @r2.id ])[:self_frequency]
      assert_not gated_dot([ @r1.id, @r2.id ])[:self_withheld]
      assert_equal "occasional", gated_dot(nil)[:self_frequency]
    end
  end

  context "carried-forward provenance" do
    should "mark a dot whose manager rating was seeded from the prior cycle" do
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
             person_id: @r1.id, framework_id: @framework_id,
             capability_stable_id: @cap.stable_id, level_ordinal: 3,
             manager_rated_frequency: "consistent", manager_rating_source: "seeded")

      ivy = dot(stats, @r1)
      assert ivy[:carried], "a seeded manager rating is carried"
      assert_equal "consistent", ivy[:frequency], "the value is still shown"
    end

    should "not mark a human or legacy rating as carried" do
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
             person_id: @r1.id, framework_id: @framework_id,
             capability_stable_id: @cap.stable_id, level_ordinal: 3,
             manager_rated_frequency: "consistent", manager_rating_source: "human")
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
             person_id: @r2.id, framework_id: @framework_id,
             capability_stable_id: @cap.stable_id, level_ordinal: 4,
             manager_rated_frequency: "some", manager_rating_source: nil)

      carried = stats[:levels].values.flatten.map { |d| d[:carried] }
      assert_equal [ false ], carried.uniq
    end
  end
end
