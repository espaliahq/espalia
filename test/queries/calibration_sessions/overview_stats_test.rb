# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::OverviewStatsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em_1 = create(:person, tenant: @tenant, name: "Mia", manager: @dept_head)
    @em_2 = create(:person, tenant: @tenant, name: "Raj", manager: @dept_head)
    @r1 = create(:person, tenant: @tenant, name: "Ivy", manager: @em_1)
    @r2 = create(:person, tenant: @tenant, name: "Omar", manager: @em_2)

    [ @r1, @r2 ].each do |person|
      create(:person_framework_assignment, tenant: @tenant,
             person_id: person.id, framework_id: @framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: person.id, level_ordinal: 3)
    end

    category = create(:framework_capability_category, tenant: @tenant,
                      framework_id: @framework_id, name: "Thinking")
    @cap_a = create(:framework_capability, tenant: @tenant,
                    category_id: category.category_id, name: "Strategic Thinking")
    @cap_b = create(:framework_capability, tenant: @tenant,
                    category_id: category.category_id, name: "Delivery")

    @session = create(:calibration_session, tenant: @tenant,
                      cycle_id: @cycle.cycle_id, framework_id: @framework_id,
                      facilitator_id: @dept_head.id, status: "started")
    [ @em_1, @em_2 ].each do |em|
      create(:calibration_session_member, :participant, tenant: @tenant,
             session: @session, person_id: em.id)
    end
    [ @r1, @r2 ].each do |person|
      create(:calibration_session_member, tenant: @tenant,
             session: @session, person_id: person.id)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def rate(person, capability, manager:, self_freq: nil, ordinal: 3, source: nil)
    create(:assessment_level_rating, tenant: @tenant,
           cycle_id: @cycle.cycle_id, person_id: person.id, framework_id: @framework_id,
           capability_stable_id: capability.stable_id, level_ordinal: ordinal,
           manager_rated_frequency: manager, self_rated_frequency: self_freq,
           manager_rating_source: source)
  end

  def stats
    CalibrationSessions::OverviewStats.new(session: @session).call
  end

  context "tendency strip" do
    should "compute per-rater mean, org delta, distribution, and self gap" do
      rate(@r1, @cap_a, manager: "consistent", self_freq: "consistent")  # Mia: 3.0
      rate(@r1, @cap_b, manager: "consistent")                          # Mia: 3.0
      rate(@r2, @cap_a, manager: "some", self_freq: "consistent")       # Raj: 1.0, self-gap -2
      rate(@r2, @cap_b, manager: "occasional")                          # Raj: 2.0

      result = stats
      assert_equal 2.25, result[:org_mean]

      mia = result[:raters].find { |r| r[:participant_id] == @em_1.id }
      raj = result[:raters].find { |r| r[:participant_id] == @em_2.id }

      assert_equal 3.0, mia[:mean]
      assert_equal 0.75, mia[:org_delta]
      assert_equal 0.0, mia[:self_gap], "self and manager agree"
      assert_equal({ "none" => 0, "some" => 0, "occasional" => 0, "consistent" => 2 }, mia[:distribution])

      assert_equal 1.5, raj[:mean]
      assert_equal(-0.75, raj[:org_delta])
      assert_equal(-2.0, raj[:self_gap], "manager rated two bands below self")
      assert raj[:small_n], "two cells is below the small-n floor"
    end

    should "ignore off-level cells and unrated cells" do
      rate(@r1, @cap_a, manager: "consistent", ordinal: 5) # not the assessed level
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
             person_id: @r1.id, framework_id: @framework_id,
             capability_stable_id: @cap_a.stable_id, level_ordinal: 3,
             self_rated_frequency: "consistent") # self only

      mia = stats[:raters].find { |r| r[:participant_id] == @em_1.id }
      assert_equal 0, mia[:cell_count]
      assert_nil mia[:mean]
    end

    should "count evidence backing on rated cells" do
      rate(@r1, @cap_a, manager: "consistent")
      rate(@r1, @cap_b, manager: "consistent")
      # The item factory writes the origin EvidenceLink alongside the row.
      create(:evidence_item, tenant: @tenant, person_id: @r1.id,
             framework_id: @framework_id,
             capability_stable_id: @cap_a.stable_id, level_ordinal: 3)

      mia = stats[:raters].find { |r| r[:participant_id] == @em_1.id }
      assert_equal 0.5, mia[:evidence_pct]
    end
  end

  context "divergence board" do
    should "rank capabilities by residual spread and name them" do
      cap_c = create(:framework_capability, tenant: @tenant,
                     category_id: @cap_a.category_id, name: "Collaboration")
      # cap_a: genuine disagreement (3.0 vs 0.0). cap_b + cap_c: agreement —
      # they anchor the raters' overall offsets so the correction doesn't
      # absorb the cap_a disagreement as mere tendency.
      rate(@r1, @cap_a, manager: "consistent")
      rate(@r2, @cap_a, manager: "none")
      rate(@r1, @cap_b, manager: "occasional")
      rate(@r2, @cap_b, manager: "occasional")
      rate(@r1, cap_c, manager: "occasional")
      rate(@r2, cap_c, manager: "occasional")

      capabilities = stats[:capabilities]
      assert_equal @cap_a.stable_id, capabilities.first[:stable_id]

      top = capabilities.first
      assert_equal "Strategic Thinking", top[:name]
      assert_equal "Thinking", top[:category_name]
      assert_equal 3.0, top[:spread]
      assert top[:residual_spread] > capabilities.last[:residual_spread]
      assert_equal 3.0, top[:rater_means][@em_1.id][:mean]
      assert_equal 0.0, top[:rater_means][@em_2.id][:mean]
    end

    should "separate rater tendency from expectation ambiguity" do
      # Raj rates everything exactly one band below Mia — pure tendency.
      # After the offset correction, residual spread collapses to ~0.
      rate(@r1, @cap_a, manager: "consistent") # 3
      rate(@r1, @cap_b, manager: "consistent") # 3
      rate(@r2, @cap_a, manager: "occasional") # 2
      rate(@r2, @cap_b, manager: "occasional") # 2

      stats[:capabilities].each do |capability|
        assert_equal 1.0, capability[:spread]
        assert_in_delta 0.0, capability[:residual_spread], 0.01,
          "uniform offset should be fully absorbed by the tendency correction"
        assert_equal 0.0, capability[:divergence_score]
        assert_not capability[:flagged]
      end
    end

    should "not flag agreement between raters with opposite tendencies" do
      # Both raters give cap_a identical means, but their overall
      # tendencies differ (via cap_b). The correction manufactures a
      # residual on cap_a — flagging it as "raters disagree" would be
      # nonsense, so the divergence score bounds it by the raw spread.
      rate(@r1, @cap_a, manager: "occasional")
      rate(@r2, @cap_a, manager: "occasional")
      rate(@r1, @cap_b, manager: "consistent")
      rate(@r2, @cap_b, manager: "none")

      agreement = stats[:capabilities].find { |c| c[:stable_id] == @cap_a.stable_id }
      assert_equal 0.0, agreement[:spread]
      assert agreement[:residual_spread] > 1.0, "correction creates an artificial residual"
      assert_equal 0.0, agreement[:divergence_score]
      assert_not agreement[:flagged]
      assert_equal @cap_b.stable_id, stats[:capabilities].first[:stable_id],
        "real disagreement ranks above corrected-away agreement"
    end

    should "exclude single-rater capabilities and count them" do
      rate(@r1, @cap_a, manager: "consistent")

      result = stats
      assert_empty result[:capabilities]
      assert_equal 1, result[:insufficient_capability_count]
    end
  end

  context "attribution" do
    should "exclude population members whose rater is not a participant" do
      other_manager = create(:person, tenant: @tenant, name: "Kim Elsewhere")
      outsider_report = create(:person, tenant: @tenant, name: "Ref Point", manager: other_manager)
      create(:person_framework_assignment, tenant: @tenant,
             person_id: outsider_report.id, framework_id: @framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: outsider_report.id, level_ordinal: 3)
      create(:calibration_session_member, tenant: @tenant,
             session: @session, person_id: outsider_report.id)
      rate(outsider_report, @cap_a, manager: "none")

      result = stats
      assert_nil result[:org_mean], "reference person's ratings never enter the stats"
    end
  end

  # Carried (seeded, unconfirmed) values still count toward every number —
  # they are real data — but each surface marks them so the room can
  # discount an inherited tendency or an unexamined disagreement.
  context "carried-forward provenance" do
    should "count carried cells per rater without changing the mean" do
      rate(@r1, @cap_a, manager: "consistent", source: "seeded")
      rate(@r2, @cap_a, manager: "none")

      mia = stats[:raters].find { |r| r[:participant_id] == @em_1.id }
      raj = stats[:raters].find { |r| r[:participant_id] == @em_2.id }

      assert_equal 1, mia[:carried_count]
      assert_equal 3.0, mia[:mean], "a carried value still counts as data"
      assert_equal 0, raj[:carried_count]
    end

    should "treat only \"seeded\" as carried — nil is a legacy human row" do
      rate(@r1, @cap_a, manager: "consistent", source: nil)
      rate(@r2, @cap_a, manager: "some", source: "human")

      assert_equal [ 0, 0 ], stats[:raters].map { |r| r[:carried_count] }
    end

    should "count carried cells behind each capability comparison" do
      rate(@r1, @cap_a, manager: "consistent", source: "seeded")
      rate(@r2, @cap_a, manager: "none")

      row = stats[:capabilities].find { |c| c[:stable_id] == @cap_a.stable_id }
      assert_equal 1, row[:carried_count]
      assert_equal 2, row[:cell_count]
      assert_equal 3.0, row[:spread], "the divergence is still ranked on real data"
    end

    should "scope the capability count to the raters whose means ARE the spread" do
      # A third rater's carried cell sits in the middle of the range, so it
      # is not part of the comparison the row displays. Counting it would
      # claim the gap is partly inherited when both extremes are vetted.
      em_3 = create(:person, tenant: @tenant, name: "Sam", manager: @dept_head)
      create(:calibration_session_member, :participant, tenant: @tenant,
             session: @session, person_id: em_3.id)
      mid = create(:person, tenant: @tenant, name: "Mid", manager: em_3)
      create(:person_framework_assignment, tenant: @tenant,
             person_id: mid.id, framework_id: @framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: mid.id, level_ordinal: 3)

      rate(@r1, @cap_a, manager: "consistent")            # 3.0 — high extreme
      rate(@r2, @cap_a, manager: "none")                  # 0.0 — low extreme
      rate(mid, @cap_a, manager: "some", source: "seeded")  # 1.0 — middle, carried

      row = stats[:capabilities].find { |c| c[:stable_id] == @cap_a.stable_id }
      assert_equal 3.0, row[:spread]
      assert_equal 0, row[:carried_count], "the middle rater isn't in the comparison"
      assert_equal 2, row[:cell_count], "only the two extreme raters' cells"
    end
  end
end
