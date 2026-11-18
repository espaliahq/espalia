# frozen_string_literal: true

require "test_helper"

class Assessments::TeamCapabilitiesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7

    @engineer = create(:framework_role, name: "Software Engineer", code: "E")
    @designer = create(:framework_role, name: "Product Designer", code: "PD")
    [ @engineer, @designer ].each do |role|
      (1..3).each { |ordinal| create(:framework_level, role_id: role.role_id, ordinal:, code: "#{role.code}#{ordinal}") }
    end

    @thinking = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking")
    @coaching = create(:framework_capability_category, framework_id: @framework_id, name: "Coaching")
    @critical = create(:framework_capability, category_id: @thinking.category_id, name: "Critical thinking")
    @player_coach = create(:framework_capability, category_id: @coaching.category_id, name: "Player coach")
    @visual = create(:framework_capability, category_id: @thinking.category_id, name: "Visual design")
    [ @critical, @player_coach ].each { |cap| bind(cap, @engineer) }
    bind(@visual, @designer)
    [ @critical, @player_coach, @visual ].each do |cap|
      (1..3).each do |ordinal|
        create(:framework_behavioural_expectation, tenant: @tenant, capability_id: cap.capability_id, level_ordinal: ordinal)
      end
    end

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, status: "open")

    @ada = enroll("Ada", @engineer, 2)
    @bo = enroll("Bo", @engineer, 3)
    @cy = enroll("Cy", @engineer, 1)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "a team on one role" do
    setup do
      rate(@ada, @critical, 2, "consistent")
      rate(@ada, @player_coach, 2, "consistent")
      rate(@bo, @critical, 3, "occasional")
      rate(@bo, @player_coach, 3, "consistent")
      rate(@cy, @critical, 1, "some")
      rate(@cy, @player_coach, 1, "consistent")
    end

    should "score each capability as the mean of everyone's score against their own level" do
      assert_in_delta 0.67, capability(@critical).score, 0.01
      assert_in_delta 1.0, capability(@player_coach).score, 0.01
    end

    should "count who is short of their own level on each capability" do
      assert_equal 2, capability(@critical).short
      assert_equal 0, capability(@player_coach).short
      assert_equal 3, capability(@critical).scored
    end

    should "list a capability as a common gap when more than half of those scored are short" do
      assert_equal [ @critical.stable_id ], result.gaps.map(&:stable_id)
    end

    should "count the capabilities the team meets on average" do
      assert_equal 1, result.met
    end

    should "count the people in view and those with a score" do
      assert_equal 3, result.people
      assert_equal 3, result.scored
    end

    should "keep the framework's order and give each category its own hue" do
      assert_equal [ @critical.stable_id, @player_coach.stable_id ], result.capabilities.map(&:stable_id)
      assert_equal %w[Thinking Coaching], result.capabilities.map(&:category_name)
      assert_not_equal(*result.capabilities.map(&:hue))
    end

    should "read only the perspective asked for" do
      rate(@ada, @critical, 2, "none", side: :self_rated_frequency)

      assert_in_delta 0.67, capability(@critical).score, 0.01
      assert_in_delta 0.0, capability(@critical, perspective: :self_only).score, 0.01
    end

    should "narrow to one level, counting the people at each" do
      narrowed = result(level_ordinal: 3)

      assert_equal({ "E1" => 1, "E2" => 1, "E3" => 1 }, result.levels.to_h { |l| [ l.code, l.people ] })
      assert_equal 1, narrowed.people
      assert_in_delta 0.67, narrowed.capabilities.first.score, 0.01
    end
  end

  should "leave out someone whose score hasn't unlocked yet" do
    rate(@ada, @critical, 2, "consistent")
    rate(@ada, @player_coach, 2, "consistent")
    rate(@bo, @critical, 3, "none")

    assert_equal 3, result.people
    assert_equal 2, result.scored
    assert_in_delta 0.5, capability(@critical).score, 0.01
    assert_equal 1, capability(@critical).short
  end

  should "ignore ratings outside the assessed role" do
    rate(@bo, @critical, 3, "consistent")
    rate(@cy, @critical, 1, "consistent")
    create_out_of_scope_rating(person_id: @ada.id, cycle: @cycle, level_ordinal: 2)

    assert_equal 2, result.scored
    assert_equal [ @critical.stable_id, @player_coach.stable_id ], result.capabilities.map(&:stable_id)
  end

  should "count someone on agreed ratings only once every cell at their level is agreed, as their hero does" do
    align(@ada, 2)
    align(@bo, 3)
    rate(@ada, @critical, 2, "consistent", side: :aligned_frequency)
    rate(@bo, @critical, 3, "consistent", side: :aligned_frequency)
    rate(@bo, @player_coach, 3, "consistent", side: :aligned_frequency)

    assert_equal 1, result(perspective: :aligned_only).scored
  end

  should "keep counting a completed alignment on agreed ratings when a cell joins after it" do
    align(@ada, 2, status: "aligned")
    align(@bo, 3, status: "aligned")
    rate(@ada, @critical, 2, "consistent", side: :aligned_frequency)
    rate(@bo, @critical, 3, "consistent", side: :aligned_frequency)
    rate(@bo, @player_coach, 3, "consistent", side: :aligned_frequency)

    assert_equal 2, result(perspective: :aligned_only).scored
  end

  should "leave a capability nobody rated out of its mean rather than scoring it 0" do
    rate(@ada, @critical, 2, "consistent")
    rate(@bo, @critical, 3, "consistent")

    assert_equal 2, capability(@critical).scored
    assert_nil capability(@player_coach).score
  end

  should "start on the role most of the team holds, and offer the others" do
    team = [ @ada, @bo, @cy, enroll("Di", @designer, 2) ].map(&:id)

    assert_equal @engineer.role_id, result(person_ids: team).role.role_id
    assert_equal({ "Software Engineer" => 3, "Product Designer" => 1 },
                 result(person_ids: team).roles.to_h { |r| [ r.name, r.people ] })
    assert_equal 1, result(person_ids: team, role_id: @designer.role_id).people
  end

  should "read the assignment's role and level for an enrollment taken before the snapshot" do
    eve = create(:person, tenant: @tenant, name: "Eve")
    create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: eve.id, status: "enrolled")
    level = FrameworkState::Level.find_by!(role_id: @engineer.role_id, ordinal: 3)
    create(:person_framework_assignment, tenant: @tenant, person_id: eve.id, framework_id: @framework_id,
                                         role_id: @engineer.role_id, level_id: level.level_id)
    rate(eve, @critical, 3, "consistent")

    narrowed = result(person_ids: [ eve.id ], level_ordinal: 3)
    assert_equal [ 1, 1 ], [ narrowed.people, narrowed.scored ]
  end

  should "read every level when the role asked for isn't in the team" do
    fallback = result(role_id: @designer.role_id, level_ordinal: 3)

    assert_equal @engineer.role_id, fallback.role.role_id
    assert_nil fallback.level_ordinal
    assert_equal 3, fallback.people
  end

  should "read every level for a level that isn't on the role's ladder" do
    narrowed = result(level_ordinal: 9)

    assert_nil narrowed.level_ordinal
    assert_equal 3, narrowed.people
  end

  should "leave out people who aren't in an open cycle" do
    closed = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, status: "closed")
    eve = create(:person, tenant: @tenant, name: "Eve")
    create(:assessment_cycle_enrollment, tenant: @tenant, cycle: closed, person_id: eve.id,
                                         role_id: @engineer.role_id, level_ordinal: 2, status: "enrolled")

    assert_equal 3, result(person_ids: [ @ada, @bo, @cy, eve ].map(&:id)).people
  end

  private

  def result(person_ids: [ @ada, @bo, @cy ].map(&:id), **options)
    Assessments::TeamCapabilities.new(person_ids:, **options).call
  end

  def capability(cap, **options)
    result(**options).capabilities.find { |c| c.stable_id == cap.stable_id }
  end

  def bind(capability, role)
    create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: role.role_id)
  end

  def enroll(name, role, ordinal)
    person = create(:person, tenant: @tenant, name:)
    create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: person.id,
                                         role_id: role.role_id, level_ordinal: ordinal, status: "enrolled")
    person
  end

  def align(person, ordinal, status: "aligning")
    AssessmentCycleRoleAlignment.create!(tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: person.id,
                                         framework_id: @framework_id, role_id: @engineer.role_id, home: true,
                                         level_ordinal: ordinal, status:, alignment_started_at: Time.current)
  end

  def rate(person, capability, ordinal, frequency, side: :manager_rated_frequency)
    rating = AssessmentLevelRating.find_by(cycle_id: @cycle.cycle_id, person_id: person.id,
                                           capability_stable_id: capability.stable_id, level_ordinal: ordinal)
    return rating.update!(side => frequency) if rating

    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: person.id,
                                     framework_id: @framework_id, capability_stable_id: capability.stable_id,
                                     level_ordinal: ordinal, side => frequency)
  end
end
