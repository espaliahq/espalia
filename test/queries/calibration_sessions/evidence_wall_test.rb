# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::EvidenceWallTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
    @cap_stable = SecureRandom.uuid_v7

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em_1 = create(:person, tenant: @tenant, name: "Mia", manager: @dept_head)
    @em_2 = create(:person, tenant: @tenant, name: "Raj", manager: @dept_head)
    @r1 = create(:person, tenant: @tenant, name: "Ivy", manager: @em_1)
    @r2 = create(:person, tenant: @tenant, name: "Omar", manager: @em_2)
    @outsider = create(:person, tenant: @tenant, name: "Zed Outside")

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
      # Attribution (rater ownership) only covers framework-assigned people.
      create(:person_framework_assignment, tenant: @tenant,
             person_id: person.id, framework_id: @framework_id)
    end

    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @r1.id, framework_id: @framework_id,
           capability_stable_id: @cap_stable, level_ordinal: 3,
           manager_rated_frequency: "consistent")
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @r2.id, framework_id: @framework_id,
           capability_stable_id: @cap_stable, level_ordinal: 4,
           manager_rated_frequency: "some")

    # Ivy: manager-authored item at L3 with a valence; Omar: self-authored at L4.
    @ivy_item = evidence_for(@r1, author: @em_1, ordinal: 3,
                             valence: "demonstrated", content: "Led the pricing work.",
                             recorded_at: 2.days.ago)
    # A second, newer L3 item — from a peer — so ordering within a level and
    # the peer relation are both exercised.
    @ivy_peer_item = evidence_for(@r1, author: @r2, ordinal: 3,
                                  valence: "strongly_demonstrated",
                                  content: "Unblocked our team's migration.",
                                  recorded_at: 1.hour.ago)
    @omar_item = evidence_for(@r2, author: @r2, ordinal: 4,
                              valence: "growth_area", content: "Ran the platform retro.",
                              recorded_at: 1.day.ago)
    # Outside the population — never on the wall.
    evidence_for(@outsider, author: @em_1, ordinal: 3, valence: "demonstrated",
                 content: "Outsider evidence.")
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def evidence_for(person, author:, ordinal:, valence:, content:, recorded_at: Time.current)
    item = create(:evidence_item, tenant: @tenant, with_link: false,
                  person_id: person.id, author: author,
                  framework_id: @framework_id, capability_stable_id: @cap_stable,
                  level_ordinal: ordinal, content: content, recorded_at: recorded_at)
    EvidenceLink.create!(
      tenant_id: @tenant.id, evidence_id: item.id, person_id: person.id,
      framework_id: @framework_id, capability_stable_id: @cap_stable,
      level_ordinal: ordinal, link_status: "active",
      linked_by_id: author.id, linked_at: recorded_at, valence: valence
    )
    item
  end

  def wall(**filters)
    CalibrationSessions::EvidenceWall.new(
      session: @session, capability_stable_id: @cap_stable, **filters
    ).call
  end

  should "group population evidence by level, highest first, newest first within" do
    result = wall

    assert_equal [ 4, 3 ], result[:groups].map { |g| g[:ordinal] }
    assert_equal 3, result[:total]

    omar = result[:groups].first[:items].first
    assert_equal "Omar", omar[:person_name]
    assert_equal @em_2.id, omar[:rater_id]
    assert_equal "some", omar[:frequency]
    assert_equal "self", omar[:relation]
    assert_equal "growth_area", omar[:valence]

    # Within L3 the newer item leads.
    l3 = result[:groups].last[:items]
    assert_equal [ "Unblocked our team's migration.", "Led the pricing work." ], l3.map { |i| i[:content] }
    assert_equal "manager", l3.last[:relation]
    assert_equal "consistent", l3.last[:frequency]
    refute result[:groups].flat_map { |g| g[:items] }
      .any? { |i| i[:content].include?("Outsider") }
  end

  should "label an item authored by neither the person nor their manager as peer" do
    peer = wall(level: 3)[:groups].first[:items].find { |i| i[:content].start_with?("Unblocked") }

    assert_equal "peer", peer[:relation]
  end

  should "list the levels and raters it holds, pre-filter, for the filter controls" do
    result = wall

    assert_equal [ 4, 3 ], result[:level_ordinals]
    assert_equal [ @em_2.id, @em_1.id ].sort, result[:rater_ids].sort
  end

  should "read a caller-supplied population instead of the whole session" do
    result = wall(person_ids: [ @r2.id ])

    assert_equal [ "Ran the platform retro." ],
                 result[:groups].flat_map { |g| g[:items] }.map { |i| i[:content] }
  end

  should "filter by level, valence, and rater independently" do
    assert_equal 2, wall(level: 3)[:total]
    assert_equal [ "Ran the platform retro." ],
                 wall(valence: "growth_area")[:groups].flat_map { |g| g[:items] }.map { |i| i[:content] }
    # Rater = who owns the person's ratings, not who authored the item: the
    # peer-authored item is still Mia's, because Ivy is Mia's report.
    assert_equal 2, wall(rater_id: @em_1.id)[:total]
    # rater filter still reports the full rater list for the control
    assert_equal 2, wall(rater_id: @em_1.id)[:rater_ids].size
  end

  should "exclude withdrawn items and inactive links" do
    [ @ivy_item, @ivy_peer_item ].each { |item| item.update!(link_status: "withdrawn") }
    EvidenceLink.where(evidence_id: @omar_item.id).update_all(link_status: "removed")

    assert_equal 0, wall[:total]
  end

  should "prefer the recorded reporting manager for the relation" do
    # Ivy's live manager changed, but the recorded manager (who authored the
    # item) still counts as "manager".
    create(:recorded_reporting_manager, tenant: @tenant, person_id: @r1.id,
           framework_id: @framework_id, manager_id: @em_1.id)
    @r1.update!(manager: @em_2)

    ivy = wall(level: 3)[:groups].first[:items].find { |i| i[:content].start_with?("Led") }
    assert_equal "manager", ivy[:relation]
  end

  should "mark a stamp whose manager rating was carried from the prior cycle" do
    AssessmentLevelRating
      .find_by(cycle_id: @cycle.cycle_id, person_id: @r1.id, level_ordinal: 3)
      .update!(manager_rating_source: "seeded")

    ivy = wall(level: 3)[:groups].first[:items].first
    assert ivy[:frequency_carried], "the stamp is marked carried"
    assert_equal "consistent", ivy[:frequency], "the grade is still shown"

    omar = wall(level: 4)[:groups].first[:items].first
    assert_not omar[:frequency_carried]
  end
end
