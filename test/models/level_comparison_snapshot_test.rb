# frozen_string_literal: true

require "test_helper"

# A snapshot of each role and level's median scores, taken from everyone's
# latest settled assessment: the alignment their manager completed for their
# home role.
class LevelComparisonSnapshotTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @fx.framework_id, status: "closed")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  # A person whose alignment for the role at the level is complete, with
  # their agreed ratings at that level.
  def settled(role: @fx.engineer, level: 2, agreed: {}, cycle: @cycle, status: "aligned", home: true, person: nil)
    person ||= create(:person, tenant: @tenant)
    AssessmentCycleRoleAlignment.create!(
      tenant: @tenant, cycle_id: cycle.cycle_id, person_id: person.id, framework_id: @fx.framework_id,
      role_id: role.role_id, level_ordinal: level, home: home, status: status,
      alignment_started_at: 2.days.ago, aligned_at: (1.day.ago if status == "aligned")
    )
    agreed.each do |capability, frequency|
      create(:assessment_level_rating, tenant: @tenant, person_id: person.id, framework_id: @fx.framework_id,
                                       cycle_id: cycle.cycle_id, capability_stable_id: capability.stable_id,
                                       level_ordinal: level, aligned_frequency: frequency)
    end
    person
  end

  def take = LevelComparisonSnapshot.take!(tenant: @tenant, on: Date.new(2026, 12, 1))

  def engineers_at_e2(snapshot) = snapshot.groups.find_by(role_id: @fx.engineer.role_id, level_ordinal: 2)

  should "keep each capability's median across the role's people at the level" do
    3.times { settled(agreed: { @fx.shared => "consistent", @fx.e_only => "none" }) }
    2.times { settled(agreed: { @fx.shared => "none", @fx.e_only => "consistent" }) }

    group = engineers_at_e2(take)

    assert_equal 5, group.group_size
    assert_equal({ @fx.shared.stable_id => 1.0, @fx.e_only.stable_id => 0.0 }, group.capability_medians)
    assert_equal Date.new(2026, 12, 1), group.snapshot.taken_on
  end

  should "keep each category's median" do
    5.times { settled(agreed: { @fx.shared => "consistent", @fx.e_only => "consistent" }) }

    assert_equal({ @fx.shared.category_id => 1.0 }, engineers_at_e2(take).category_medians)
  end

  should "count only settled assessments, each person's latest" do
    3.times { settled(agreed: { @fx.shared => "consistent" }) }
    settled(agreed: { @fx.shared => "consistent" }, status: "aligning")
    settled(agreed: { @fx.shared => "consistent" }, home: false)
    reopened = settled(agreed: { @fx.shared => "none" })
    later = create(:assessment_cycle, tenant: @tenant, framework_id: @fx.framework_id)
    settled(person: reopened, cycle: later, agreed: { @fx.shared => "consistent" }, status: "aligning")

    group = engineers_at_e2(take)

    assert_equal 4, group.group_size, "expected the three settled, and the reopened one at their previous alignment"
    assert_equal 1.0, group.capability_medians[@fx.shared.stable_id]
  end

  should "score a person on their latest completed alignment, not an earlier one" do
    person = settled(agreed: { @fx.shared => "consistent" })
    AssessmentCycleRoleAlignment.find_by!(person_id: person.id).update!(aligned_at: 1.day.ago)
    earlier = create(:assessment_cycle, tenant: @tenant, framework_id: @fx.framework_id, status: "closed",
                                        opened_at: 1.year.ago)
    settled(person:, cycle: earlier, agreed: { @fx.shared => "none" })
    AssessmentCycleRoleAlignment.find_by!(person_id: person.id, cycle_id: earlier.cycle_id).update!(aligned_at: 1.year.ago)

    group = engineers_at_e2(take)

    assert_equal 1, group.group_size
    assert_equal 1.0, group.capability_medians[@fx.shared.stable_id]
  end

  should "take the median of an even group as the mean of its two middle scores" do
    settled(agreed: { @fx.shared => "consistent" })
    settled(agreed: { @fx.shared => "none" })

    assert_equal 0.5, engineers_at_e2(take).capability_medians[@fx.shared.stable_id]
  end

  should "score a person on their most recent cycle, even when an older one's alignment completed later" do
    person = settled(agreed: { @fx.shared => "consistent" })
    @cycle.update!(opened_at: 1.month.ago)
    AssessmentCycleRoleAlignment.find_by!(person_id: person.id).update!(aligned_at: 1.week.ago)
    older = create(:assessment_cycle, tenant: @tenant, framework_id: @fx.framework_id, status: "closed", opened_at: 1.year.ago)
    settled(person:, cycle: older, agreed: { @fx.shared => "none" })
    AssessmentCycleRoleAlignment.find_by!(person_id: person.id, cycle_id: older.cycle_id).update!(aligned_at: 1.day.ago)

    assert_equal 1.0, engineers_at_e2(take).capability_medians[@fx.shared.stable_id]
  end

  should "leave out people who have been forgotten" do
    2.times { settled(agreed: { @fx.shared => "consistent" }) }
    settled(agreed: { @fx.shared => "none" }).update_columns(forgotten_at: Time.current, name: "Former member", email: nil)

    assert_equal 2, engineers_at_e2(take).group_size
  end

  should "leave out people who have left" do
    3.times { settled(agreed: { @fx.shared => "consistent" }) }
    settled(agreed: { @fx.shared => "none" }).update!(status: "inactive")

    assert_equal 3, engineers_at_e2(take).group_size
  end

  should "keep a group per role and level" do
    2.times { settled(level: 2) }
    settled(level: 3)
    settled(role: @fx.pm)

    groups = take.groups.map { |g| [ g.role_id, g.level_ordinal, g.group_size ] }.sort

    assert_equal [ [ @fx.engineer.role_id, 2, 2 ], [ @fx.engineer.role_id, 3, 1 ], [ @fx.pm.role_id, 2, 1 ] ].sort, groups
  end

  should "ignore ratings outside the assessed role" do
    person = settled(agreed: { @fx.shared => "consistent" })
    create_out_of_scope_rating(person_id: person.id, cycle: @cycle, level_ordinal: 2)

    assert_equal [ @fx.shared.stable_id, @fx.e_only.stable_id ].sort, engineers_at_e2(take).capability_medians.keys.sort
  end
end
