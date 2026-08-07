# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::PersonCardTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em = create(:person, tenant: @tenant, name: "Mia", manager: @dept_head)
    @report = create(:person, tenant: @tenant, name: "Ivy", manager: @em)
    @peer = create(:person, tenant: @tenant, name: "Pat Peer", manager: @em)

    # Real PD assignments — a revisit ask mirrors onto the person's stream,
    # whose aggregate requires one. Assigned BEFORE the cycle row exists so
    # AutoEnrollNewAssignments doesn't reach for a factory cycle that has no
    # event stream.
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      [ @report, @peer ].each do |person|
        PersonDevelopment::CommandHandler.new.assign_to_framework(
          person.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7
        )
      end
    end

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)

    category = create(:framework_capability_category, tenant: @tenant,
                      framework_id: @framework_id, name: "Thinking")
    @cap = create(:framework_capability, tenant: @tenant,
                  category_id: category.category_id, name: "Strategic Thinking")
    create(:framework_behavioural_expectation, tenant: @tenant,
           capability_id: @cap.capability_id, level_ordinal: 3,
           description: "Identifies root causes.")

    # The assignment rows already exist — the PD command above projected them.
    [ @report, @peer ].each do |person|
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: person.id, level_ordinal: 3)
    end
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @report.id, framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 3,
           manager_rated_frequency: "consistent")

    @session = create(:calibration_session, tenant: @tenant,
                      cycle_id: @cycle.cycle_id, framework_id: @framework_id,
                      facilitator_id: @dept_head.id, status: "started")
    create(:calibration_session_member, :participant, tenant: @tenant,
           session: @session, person_id: @em.id)
    [ @report, @peer ].each do |person|
      create(:calibration_session_member, tenant: @tenant,
             session: @session, person_id: person.id)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def link_evidence(author:, content:, person: @report, ordinal: 3)
    item = create(:evidence_item, tenant: @tenant, with_link: false,
                  person_id: person.id, author: author, framework_id: @framework_id,
                  capability_stable_id: @cap.stable_id, level_ordinal: ordinal,
                  content: content)
    EvidenceLink.create!(
      tenant_id: @tenant.id, evidence_id: item.id, person_id: person.id,
      framework_id: @framework_id, capability_stable_id: @cap.stable_id,
      level_ordinal: ordinal, link_status: "active", linked_by_id: author.id,
      linked_at: item.recorded_at, valence: "demonstrated"
    )
    item
  end

  # The card reads revisit asks off the session's event stream, so the
  # factory row needs a real stream behind it.
  def request_revisit(person_id:, level_ordinal:)
    handler = AssessmentCycles::CalibrationCommandHandler.new
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      unless @stream_started
        handler.define_session(@session.id, @cycle.cycle_id, @framework_id, @session.name, 1,
                               facilitator_id: @dept_head.id, participant_ids: [ @em.id ],
                               calibrant_person_ids: [ @report.id, @peer.id ])
        handler.start_session(@session.id, started_by_id: @dept_head.id)
        @stream_started = true
      end
      handler.request_rating_revisit(
        @session.id, person_id: person_id, capability_stable_id: @cap.stable_id,
        level_ordinal: level_ordinal, rater_id: @em.id,
        note: "Compare against the two peers.", requested_by_id: @dept_head.id
      )
    end
  end

  def cards
    CalibrationSessions::PersonCard.new(
      session: @session, stats: stats, capability_stable_id: @cap.stable_id
    )
  end

  def stats
    @stats ||= CalibrationSessions::DrillInStats.new(
      session: @session, capability_stable_id: @cap.stable_id
    ).call
  end

  should "assemble the whole ladder: per-level ratings, expectations, and evidence" do
    # The enrollment carries no role snapshot in this fixture, so the
    # ladder degrades to just the assessed level…
    assert_equal [ { ordinal: 3, code: "L3" } ], cards.for(@report.id)[:levels]

    # …and with a snapshot, it is the role's full ladder.
    role = create(:framework_role, tenant: @tenant, name: "Engineer", code: "E",
                  role_family_id: create(:framework_role_family, tenant: @tenant,
                                         framework_id: @framework_id).role_family_id)
    [ 3, 4 ].each do |ordinal|
      create(:framework_level, tenant: @tenant, role_id: role.role_id,
             ordinal: ordinal, code: "E#{ordinal}")
    end
    AssessmentCycleEnrollment.find_by(cycle_id: @cycle.cycle_id, person_id: @report.id)
      .update!(role_id: role.role_id)

    # Rated ABOVE the assessed level — the card must not throw that away.
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @report.id, framework_id: @framework_id,
           capability_stable_id: @cap.stable_id, level_ordinal: 4,
           manager_rated_frequency: "occasional", manager_rating_source: "seeded",
           self_rated_frequency: "consistent")
    create(:framework_behavioural_expectation, tenant: @tenant,
           capability_id: @cap.capability_id, level_ordinal: 4,
           description: "Shapes system direction.")
    link_evidence(author: @em, content: "Operating at staff scope.", ordinal: 4)
    link_evidence(author: @em, content: "Root-caused the outage.", ordinal: 3)

    card = cards.for(@report.id)
    assert_equal %w[E3 E4], card[:levels].map { |level| level[:code] }
    assert_equal({ manager: "occasional", manager_carried: true, self: "consistent" },
                 card[:ratings_by_level][4])
    assert_equal "Shapes system direction.", card[:expectations_by_level][4]
    assert_equal [ "Operating at staff scope." ],
                 card[:evidence_by_level][4].map { |entry| entry[:content] }
    assert_equal [ "Root-caused the outage." ],
                 card[:evidence_by_level][3].map { |entry| entry[:content] }
    assert_equal card[:evidence_by_level][3], card[:evidence],
                 "the at-level list is the assessed level's slice"
    assert_not card[:self_withheld]
  end

  should "withhold per-level self ratings from a viewer outside the entitlement set" do
    restricted = CalibrationSessions::PersonCard.new(
      session: @session, stats: stats, capability_stable_id: @cap.stable_id,
      visible_person_ids: []
    )
    card = restricted.for(@report.id)

    assert card[:self_withheld]
    assert_nil card[:ratings_by_level][3][:self]
    assert_equal "consistent", card[:ratings_by_level][3][:manager],
                 "manager ratings are the session's business — always shown"
    assert_empty card[:evidence_by_level]
  end

  should "locate the person's dot, level, and owning rater" do
    card = cards.for(@report.id)

    assert_equal @report.id, card[:dot][:person_id]
    assert_equal 3, card[:ordinal]
    assert_equal @em.id, card[:rater_id]
  end

  should "return nil for a blank id or someone not on this grid" do
    assert_nil cards.for(nil)
    assert_nil cards.for("")
    assert_nil cards.for(create(:person, tenant: @tenant).id)
  end

  should "label evidence authorship self, manager, or peer" do
    link_evidence(author: @report, content: "I led the migration.")
    link_evidence(author: @em, content: "Ivy led the migration.")
    link_evidence(author: @peer, content: "Ivy unblocked us.")

    relations = cards.for(@report.id)[:evidence].to_h { |e| [ e[:content], e[:relation] ] }

    assert_equal "self", relations["I led the migration."]
    assert_equal "manager", relations["Ivy led the migration."]
    assert_equal "peer", relations["Ivy unblocked us."]
  end

  should "prefer the recorded reporting manager over the live one" do
    create(:recorded_reporting_manager, tenant: @tenant, person_id: @report.id,
           framework_id: @framework_id, manager_id: @em.id)
    @report.update!(manager: @dept_head)
    link_evidence(author: @em, content: "Still the recorded manager.")

    assert_equal "manager", cards.for(@report.id)[:evidence].first[:relation]
  end

  should "omit withdrawn items, removed links, and evidence linked at another level" do
    link_evidence(author: @em, content: "Withdrawn item.").update!(link_status: "withdrawn")
    unlinked = link_evidence(author: @em, content: "Removed link.")
    EvidenceLink.where(evidence_id: unlinked.id).update_all(link_status: "removed")
    link_evidence(author: @em, content: "Different level.", ordinal: 4)
    link_evidence(author: @em, content: "At this level.")

    assert_equal [ "At this level." ], cards.for(@report.id)[:evidence].map { |e| e[:content] }
  end

  should "flag a revisit only for the matching person, capability, and level" do
    refute cards.for(@report.id)[:revisit_requested]

    request_revisit(person_id: @report.id, level_ordinal: 3)
    request_revisit(person_id: @peer.id, level_ordinal: 4)

    assert cards.for(@report.id)[:revisit_requested]
    # The peer's ask is at another level, so their card still offers one.
    refute cards.for(@peer.id)[:revisit_requested]
  end

  should "still suppress a second ask when many notes were recorded after it" do
    # The revisit read must not be capped: an ask buried under later session
    # chatter would otherwise re-offer the form, which the aggregate then
    # refuses. 300 notes is past any read cap a feed would want.
    request_revisit(person_id: @report.id, level_ordinal: 3)
    handler = AssessmentCycles::CalibrationCommandHandler.new
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      300.times do |i|
        handler.record_note(@session.id, body: "Minute #{i}.", recorded_by_id: @dept_head.id)
      end
    end

    assert cards.for(@report.id)[:revisit_requested],
      "the ask is still known however much followed it"
  end

  should "memoize per person so the tray can resolve then render for free" do
    link_evidence(author: @em, content: "Ivy led the migration.")
    subject = cards

    first = subject.for(@report.id)
    second = nil
    assert_no_queries { second = subject.for(@report.id) }
    assert_same first, second

    # Misses are memoized too — a stale pin is asked about twice. A miss
    # costs no queries either way, so booby-trap the data `locate` walks:
    # asking again must NOT re-enter it. A truthiness guard (rather than
    # `key?`) would recompute and trip the wire.
    stale = create(:person, tenant: @tenant).id
    assert_nil subject.for(stale)

    tripwire = Object.new
    def tripwire.[](*) = raise("recomputed a memoized miss")
    subject.instance_variable_set(:@stats, tripwire)
    assert_nil subject.for(stale), "a miss must be served from the memo"
  end

  def assert_no_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    assert_equal 0, count, "expected no queries, got #{count}"
  end
end
