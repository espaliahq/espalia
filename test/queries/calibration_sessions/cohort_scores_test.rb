# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::CohortScoresTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em_1 = create(:person, tenant: @tenant, name: "Mia", manager: @dept_head)
    @em_2 = create(:person, tenant: @tenant, name: "Raj", manager: @dept_head)
    @r1 = create(:person, tenant: @tenant, name: "Ivy", manager: @em_1)   # L3
    @r2 = create(:person, tenant: @tenant, name: "Omar", manager: @em_2)  # L3
    @r3 = create(:person, tenant: @tenant, name: "Pax", manager: @em_2)   # L4

    # Real level ladder: Scoring sums contributions over the framework's
    # level ordinals — without Level rows every ratio degenerates to 0.
    family = create(:framework_role_family, tenant: @tenant, framework_id: @framework_id)
    @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer",
                       code: "E", role_family_id: family.role_family_id)
    (1..5).each do |ordinal|
      create(:framework_level, tenant: @tenant, role_id: @engineer.role_id,
             ordinal: ordinal, title: "E#{ordinal}", code: "E#{ordinal}")
    end

    { @r1 => 3, @r2 => 3, @r3 => 4 }.each do |person, ordinal|
      create(:person_framework_assignment, tenant: @tenant,
             person_id: person.id, framework_id: @framework_id, role_id: @engineer.role_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: person.id, level_ordinal: ordinal, role_id: @engineer.role_id)
    end

    category = create(:framework_capability_category, tenant: @tenant,
                      framework_id: @framework_id, name: "Thinking")
    # Two capabilities with expectations at L3 and L4 — the at-level
    # denominator is 2 everywhere, so the unlock target is 1.
    @cap_a = create(:framework_capability, tenant: @tenant,
                    category_id: category.category_id, name: "Strategic Thinking")
    @cap_b = create(:framework_capability, tenant: @tenant,
                    category_id: category.category_id, name: "Delivery")
    [ @cap_a, @cap_b ].each do |cap|
      create(:framework_capability_role_binding, tenant: @tenant,
             capability_id: cap.capability_id, role_id: @engineer.role_id)
      [ 3, 4 ].each do |ordinal|
        create(:framework_behavioural_expectation, tenant: @tenant,
               capability_id: cap.capability_id, level_ordinal: ordinal)
      end
    end

    @session = create(:calibration_session, tenant: @tenant,
                      cycle_id: @cycle.cycle_id, framework_id: @framework_id,
                      facilitator_id: @dept_head.id, status: "started")
    [ @em_1, @em_2 ].each do |em|
      create(:calibration_session_member, :participant, tenant: @tenant,
             session: @session, person_id: em.id)
    end
    [ @r1, @r2, @r3 ].each do |person|
      create(:calibration_session_member, tenant: @tenant,
             session: @session, person_id: person.id)
    end
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def rate(person, capability, frequency, ordinal: 3, source: nil)
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: person.id, framework_id: @framework_id,
           capability_stable_id: capability.stable_id, level_ordinal: ordinal,
           manager_rated_frequency: frequency, manager_rating_source: source)
  end

  def scores
    CalibrationSessions::CohortScores.new(session: @session).call
  end

  def dot_for(person)
    scores[:cohorts].flat_map { |c| c[:people] }.find { |d| d[:person_id] == person.id }
  end

  should "group people into level cohorts with the assessment's own number" do
    # Ivy consistent everywhere at L3 → exactly meeting → 100%.
    rate(@r1, @cap_a, "consistent")
    rate(@r1, @cap_b, "consistent")
    # Omar: one consistent, one some → below.
    rate(@r2, @cap_a, "some")
    rate(@r2, @cap_b, "consistent")
    rate(@r3, @cap_a, "consistent", ordinal: 4)
    rate(@r3, @cap_b, "consistent", ordinal: 4)

    result = scores
    assert_equal [ 3, 4 ], result[:cohorts].map { |c| c[:ordinal] }

    ivy = dot_for(@r1)
    assert_equal 100, ivy[:pct], "consistent at level = 100% of expected, the hero's arithmetic"
    assert_equal @em_1.id, ivy[:rater_id]
    assert dot_for(@r2)[:pct] < 100, "a some-rated cell pulls below expected"
    assert_equal 100, dot_for(@r3)[:pct]

    l3 = result[:cohorts].first
    assert_equal [ @r2.id, @r1.id ], l3[:people].map { |d| d[:person_id] },
                 "lowest score leads — the cohort reads as a distribution"
    assert_equal ((dot_for(@r2)[:pct] + 100) / 2.0).round, l3[:median_pct]
  end

  should "compare only manager judgments — self ratings never move the number" do
    # The trap is the :effective fallback chain (aligned → manager → self):
    # it only shows on a cell the manager HASN'T rated. Ivy self-rates that
    # cell "consistent" — under :effective she'd read 100%; manager-only
    # scores the unrated cell as unmet.
    rate(@r1, @cap_a, "consistent")
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @r1.id, framework_id: @framework_id,
           capability_stable_id: @cap_b.stable_id, level_ordinal: 3,
           self_rated_frequency: "consistent")

    # Half the L3 band: met on cap_a, unmet on cap_b — the hero's own
    # level-independent arithmetic (ADR-21). Under :effective the self
    # rating would fill cap_b's L3 and this reads 100.
    assert_equal 50, dot_for(@r1)[:pct],
                 "the room calibrates raters; the assessee's private input stays out"
  end

  should "gate the score below the unlock threshold, saying how far along" do
    # 0 of 2 rated — below the 50% unlock (target 1).
    pax = dot_for(@r3)

    assert_not pax[:unlocked]
    assert_nil pax[:pct], "no misleadingly-low number for an unrated person"
    assert_equal 0, pax[:rated]
    assert_equal 2, pax[:total]
    assert_equal 1, pax[:unlock_target]
  end

  should "count a carried rating toward coverage AND disclose it" do
    rate(@r1, @cap_a, "consistent", source: "seeded")
    rate(@r1, @cap_b, "consistent", source: "seeded")

    ivy = dot_for(@r1)
    assert ivy[:unlocked], "carried ratings are real ratings — the score shows"
    assert_equal 100, ivy[:pct]
    assert_equal 2, ivy[:carried_count]
    assert ivy[:carried_majority], "…and the dot wears the disclosure"

    rate(@r2, @cap_a, "consistent")
    assert_not dot_for(@r2)[:carried_majority]
  end

  should "not let an ineligible rating unlock a score" do
    # A rating on a capability that is bound to no role — Scoring never
    # reads it, so it must not count toward coverage either. Without the
    # eligibility filter this row alone (1 >= unlock target 1) unlocks a
    # score computed from zero usable data.
    unbound = create(:framework_capability, tenant: @tenant,
                     category_id: @cap_a.category_id, name: "Orphaned")
    create(:framework_behavioural_expectation, tenant: @tenant,
           capability_id: unbound.capability_id, level_ordinal: 3)
    rate(@r1, unbound, "consistent")

    ivy = dot_for(@r1)
    assert_not ivy[:unlocked], "an unbound capability's rating is not coverage"
    assert_equal 0, ivy[:rated]
    assert_equal 2, ivy[:total]
  end

  should "surface a pre-snapshot enrollment as gated with the reason, not silence" do
    # An enrollment written before the ADR-19 role snapshot carries no
    # role_id — un-scorable, but vanishing would misread as "not enrolled".
    drift = create(:person, tenant: @tenant, name: "Quinn", manager: @em_1)
    create(:calibration_session_member, tenant: @tenant,
           session: @session, person_id: drift.id)
    create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
           person_id: drift.id, level_ordinal: 3, role_id: nil)

    dot = dot_for(drift)
    assert dot, "the person still appears in their cohort"
    assert dot[:role_missing]
    assert_not dot[:unlocked]
    assert_nil dot[:pct]
  end

  should "exclude gated people from the median" do
    rate(@r1, @cap_a, "consistent")
    rate(@r1, @cap_b, "consistent")
    # Omar stays gated at L3; Pax gated at L4 → L4 median nil.

    result = scores
    l3 = result[:cohorts].find { |c| c[:ordinal] == 3 }
    l4 = result[:cohorts].find { |c| c[:ordinal] == 4 }
    assert_equal 100, l3[:median_pct], "only Ivy's unlocked score counts"
    assert_nil l4[:median_pct]
  end

  # #421: the rows read as a share of what the level expects, on the same
  # scale as the axis beside them — they used to be weight-unit deltas that
  # could only be compared against the other rows in the same drawer.
  context "#why_for" do
    setup do
      rate(@r1, @cap_a, "none")        # nothing shown at the level → 0%
      rate(@r1, @cap_b, "consistent")  # meets the level exactly → 100%
    end

    should "name the capabilities pulling the score down, lowest first" do
      why = CalibrationSessions::CohortScores.new(session: @session).why_for(@r1.id)

      assert_equal [ "Strategic Thinking" ], why[:weakest].map { |c| c[:name] },
                   "only capabilities below what the level expects are 'pulling down'"
      assert_operator why[:weakest].first[:score], :<, 100
      assert_empty why[:strongest],
                   "a capability at exactly 100% meets the level — it is not 'pulling it up'"
    end

    should "list only genuinely-positive contributions as pulling it up" do
      # Delivery consistent ABOVE the level too → past 100% of it.
      rate(@r1, @cap_b, "consistent", ordinal: 4)

      why = CalibrationSessions::CohortScores.new(session: @session).why_for(@r1.id)

      assert_equal [ "Delivery" ], why[:strongest].map { |c| c[:name] }
      assert_operator why[:strongest].first[:score], :>, 100
    end

    should "carry the weight, because this drawer compares people" do
      why = CalibrationSessions::CohortScores.new(session: @session).why_for(@r1.id)

      # A capability that counts double drags the score twice as hard, and
      # a percentage on its own hides that.
      assert why[:weakest].first.key?(:weight), "the row must say how much it counts for"
      assert_operator why[:weakest].first[:weight], :>, 0
    end

    should "wear the same state vocabulary as the person's own assessment" do
      why = CalibrationSessions::CohortScores.new(session: @session).why_for(@r1.id)

      assert_equal :underperforming, why[:weakest].first[:state]
    end

    should "return nil for a gated or unknown person" do
      query = CalibrationSessions::CohortScores.new(session: @session)
      assert_nil query.why_for(@r3.id), "no why-panel for a score that isn't shown"
      assert_nil query.why_for(SecureRandom.uuid_v7)
    end
  end
end
