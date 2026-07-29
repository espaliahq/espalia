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

    { @r1 => 3, @r2 => 4, @ref => 3 }.each do |person, ordinal|
      create(:person_framework_assignment, tenant: @tenant,
             person_id: person.id, framework_id: @framework_id, role_id: @engineer.role_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: person.id, level_ordinal: ordinal)
    end

    category = create(:framework_capability_category, tenant: @tenant,
                      framework_id: @framework_id, name: "Thinking")
    @cap = create(:framework_capability, tenant: @tenant,
                  category_id: category.category_id, name: "Strategic Thinking")
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

  should "place each member at (their rater, their assessed level) with rating + backing" do
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @r1.id, framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 3,
           manager_rated_frequency: "consistent", self_rated_frequency: "occasional")
    create(:evidence_item, tenant: @tenant, person_id: @r1.id,
           framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 3)

    result = stats
    mia_row = result[:rows].find { |row| row[:rater_id] == @em_1.id }
    dot = mia_row[:people][3].first

    assert_equal @r1.id, dot[:person_id]
    assert_equal "Ivy", dot[:name]
    assert_equal "consistent", dot[:frequency]
    assert_equal "occasional", dot[:self_frequency]
    assert dot[:backed]
  end

  should "render unrated members as frequency-nil dots" do
    result = stats
    raj_row = result[:rows].find { |row| row[:rater_id] == @em_2.id }
    dot = raj_row[:people][4].first

    assert_equal "Omar", dot[:name]
    assert_nil dot[:frequency]
    assert_not dot[:backed]
  end

  should "group members with out-of-session raters into a trailing nil row" do
    result = stats
    other_row = result[:rows].last

    assert_nil other_row[:rater_id]
    assert_not other_row[:in_session]
    assert_equal [ "Ref Point" ], other_row[:people][3].map { |d| d[:name] }
  end

  should "ignore ratings at a different level than the assessed one" do
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @r1.id, framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 5,
           manager_rated_frequency: "consistent")

    dot = stats[:rows].find { |row| row[:rater_id] == @em_1.id }[:people][3].first
    assert_nil dot[:frequency]
  end

  context "illustrations" do
    setup do
      illustrate(@engineer, "Unwinds a circular dependency without help.")
      illustrate(@manager_role, "Coaches the team through the trade-off.")
    end

    should "include only the roles being calibrated at that level" do
      groups = stats[:illustrations][3]

      assert_equal [ "Software Engineer" ], groups.map { |g| g[:role_name] }
      assert_equal [ "Unwinds a circular dependency without help." ], groups.first[:items]
    end

    should "include a role once the population holds it" do
      # Re-assign one L3 member to the manager role — now both are calibrated
      # at L3 and both sets of examples are relevant.
      PersonFrameworkAssignment
        .find_by(person_id: @ref.id, framework_id: @framework_id)
        .update!(role_id: @manager_role.role_id)

      assert_equal [ "Engineering Manager", "Software Engineer" ],
                   stats[:illustrations][3].map { |g| g[:role_name] }
    end

    should "leave a level with no illustrations for its roles empty" do
      assert_nil stats[:illustrations][4]
    end
  end

  def illustrate(role, description)
    create(:framework_role_illustration, tenant: @tenant,
           expectation_id: @exp_l3.expectation_id, role_id: role.role_id,
           description: description)
  end
end
