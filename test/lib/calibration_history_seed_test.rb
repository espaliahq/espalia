# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/tasks/calibration_history_seed")

# The history seed is dev data, but it drives real domain commands — close,
# enrol, carry, confirm — and a seed that silently produces a tenant with no
# carried ratings would quietly defeat every surface it exists to demo.
class CalibrationHistorySeedTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @framework = create(:framework_state, tenant: @tenant,
                        framework_id: @framework_id, current_published_version: 1)

    @head = create(:person, tenant: @tenant, name: "Dana Dept")
    # Three raters, because the personas are assigned by rank: with fewer
    # than three, "some vet and some coast" cannot be shown at all.
    @ems = %w[Mia Raj Sam].map { |name| create(:person, tenant: @tenant, name: name, manager: @head) }

    role = create(:framework_role, tenant: @tenant, name: "Software Engineer", code: "E")
    level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 3)
    category = create(:framework_capability_category, tenant: @tenant,
                      framework_id: @framework_id, name: "Thinking")
    @cap = create(:framework_capability, tenant: @tenant,
                  category_id: category.category_id, name: "Strategic Thinking")
    create(:framework_behavioural_expectation, tenant: @tenant,
           capability_id: @cap.capability_id, level_ordinal: 3)

    # A real cycle on a real stream, with real assignments — the seed closes
    # this one and carries out of it.
    @reports = @ems.flat_map do |em|
      Array.new(3) { |i| create(:person, tenant: @tenant, name: "#{em.name} report #{i}", manager: em) }
    end

    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      @reports.each do |person|
        PersonDevelopment::CommandHandler.new.assign_to_framework(
          person.id, @framework_id, role.role_id, level.level_id
        )
      end

      @cycle_id = SecureRandom.uuid_v7
      AssessmentCycles::CommandHandler.new.define_cycle(
        @cycle_id, @framework_id, "Q1 2026 Review", "regular", 1, defined_by: @head.id
      )
      @reports.each do |person|
        AssessmentCycles::CommandHandler.new.enroll(
          @cycle_id, person.id, enrolled_by: @head.id,
          role_id: role.role_id, level_id: level.level_id
        )
        PersonDevelopment::CommandHandler.new.rate_as_manager(
          person.id, @framework_id, @cap.stable_id,
          level_ordinal: 3, frequency: "occasional",
          cycle_id: @cycle_id, rated_by_id: person.manager_id, source: "human"
        )
      end
    end
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def run_seed
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      CalibrationHistorySeed.new(tenant: @tenant, framework: @framework, io: StringIO.new).call
    end
  end

  should "close the open cycle and carry its ratings into the next one" do
    stats = run_seed

    assert_operator stats[:cycles_opened], :>=, 1
    assert_equal "closed", AssessmentCycle.find_by(cycle_id: @cycle_id).status

    latest = AssessmentCycle.for_framework(@framework_id).open_cycles.first
    assert_equal CalibrationHistorySeed::FUTURE_CYCLES.last, latest.name

    ratings = AssessmentLevelRating.for_cycle(latest.cycle_id)
      .where.not(manager_rated_frequency: nil)
    assert ratings.exists?, "the new cycle must inherit the previous one's ratings"
    assert ratings.where(manager_rating_source: "seeded").exists?,
      "carried values must arrive as genuinely seeded, not hand-written"
  end

  should "leave some raters vetting and some coasting" do
    stats = run_seed

    # All three states, every run — the Carried column's whole demo. Ranked
    # assignment is what makes this an invariant rather than a coin flip.
    assert_operator stats[:raters_vetting_fully], :>=, 1
    assert_operator stats[:raters_vetting_partly], :>=, 1
    assert_operator stats[:raters_coasting], :>=, 1

    latest = AssessmentCycle.for_framework(@framework_id).open_cycles.first
    sources = AssessmentLevelRating.for_cycle(latest.cycle_id)
      .where.not(manager_rated_frequency: nil)
      .pluck(:manager_rating_source).uniq

    assert_includes sources, "seeded", "a coasting rater's row stays carried"
    assert_includes sources, "human", "a vetting rater's row becomes their own again"
  end

  should "record a moved reporting line on the person's stream" do
    stats = run_seed

    # Movers are taken by RANK, so the count is a function of the population
    # (9 reports × 0.12, rounded up = 2) not of a per-person coin flip: two
    # advances, two moves each. An independent draw would vary run to run —
    # and can move nobody at all, which is the state that leaves the
    # recorded-vs-live distinction undemonstrated.
    assert_equal 4, stats[:reporting_moves]

    # A move is deterministic per person, so assert on the invariant rather
    # than on which person drew it: every recorded manager must be a real
    # rater, and at least one must have been written by the seed.
    recorded = RecordedReportingManager.where(framework_id: @framework_id)
    assert recorded.exists?, "a move must be recorded, not just applied to the org chart"
    assert_equal [], recorded.pluck(:manager_id) - @ems.map(&:id),
      "moves stay within the same department head's raters"

    recorded.each do |row|
      assert_equal row.manager_id, Person.find(row.person_id).manager_id,
        "the recorded fact and the live chart must agree right after a move"
    end
  end

  should "not grow a history seeded under older cycle names" do
    run_seed
    AssessmentCycle.for_framework(@framework_id).where(name: CalibrationHistorySeed::FUTURE_CYCLES)
      .each_with_index { |cycle, i| cycle.update_columns(name: "Old name #{i}") }

    assert_no_difference -> { AssessmentCycle.for_framework(@framework_id).count } do
      run_seed
    end
  end

  should "move a report only to a rater in their manager's department" do
    mia, raj, sam = @ems
    mia.update!(department: "Engineering")
    raj.update!(department: "Engineering")
    sam.update!(department: "Product")
    seed = CalibrationHistorySeed.new(tenant: @tenant, framework: @framework, io: StringIO.new)

    assert_equal raj, seed.send(:sibling_rater_for, @reports.find { |p| p.manager_id == mia.id })
    assert_nil seed.send(:sibling_rater_for, @reports.find { |p| p.manager_id == sam.id }),
      "a product report has no product sibling to move to"
  end

  should "move the same people whatever ids a seed run gave them" do
    seed = CalibrationHistorySeed.new(tenant: @tenant, framework: @framework, io: StringIO.new)
    cycle = AssessmentCycle.new(name: CalibrationHistorySeed::FUTURE_CYCLES.first)
    draw = lambda do
      people = Array.new(20) { |i| build(:person, id: SecureRandom.uuid_v7, email: "person#{i}@seed.example") }
      seed.send(:move_order, cycle, people).map(&:email)
    end

    assert_equal draw.call, draw.call
  end

  should "never move a rater's last report" do
    mia, raj, = @ems
    mias = @reports.select { |person| person.manager_id == mia.id }
    mias.drop(1).each { |person| person.update!(manager: raj) }
    seed = CalibrationHistorySeed.new(tenant: @tenant, framework: @framework, io: StringIO.new)
    cycle = AssessmentCycle.find_by!(cycle_id: @cycle_id)

    first_in_line = ->(_cycle, people) { people.sort_by { |person| person == mias.first ? 0 : 1 } }

    seed.stub(:move_order, first_in_line) { seed.send(:move_reporting_lines, cycle) }

    assert_equal mia.id, mias.first.reload.manager_id
  end

  should "leave a live session on the current cycle" do
    stats = run_seed

    assert_equal 1, stats[:sessions_started]
    session = CalibrationSession.sole
    assert_equal "started", session.status
    assert_equal AssessmentCycle.for_framework(@framework_id).open_cycles.first.cycle_id,
                 session.cycle_id

    # The population rules in miniature: raters are in the room, never
    # calibrated by it, and the facilitator is in neither list.
    members = CalibrationSessionMember.where(session_id: session.id)
    raters = members.participants.pluck(:person_id)
    calibrants = members.calibrants.pluck(:person_id)

    # Every EM: the moves never take a rater's last report.
    assert_equal @ems.map(&:id).sort, raters.sort
    assert_equal [], raters & calibrants, "a rater is never their own calibrant"
    assert_not_includes calibrants, @head.id, "the facilitator is not calibrated"
    assert_equal [], calibrants - @reports.map(&:id), "only reports are calibrated"

    # Every rater in the room owns at least one person on the grid, and
    # everyone on the grid is owned by a rater in the room.
    owners = Person.where(id: calibrants).pluck(:manager_id).uniq
    assert_equal raters.sort, owners.sort
  end

  should "converge rather than grow when run twice" do
    run_seed
    cycles_after_first = AssessmentCycle.count

    second = run_seed

    assert_equal cycles_after_first, AssessmentCycle.count,
      "a re-run must not keep opening cycles"
    assert_equal 0, second[:cycles_opened]
    assert_equal 1, CalibrationSession.count, "nor keep defining sessions"
  end
end
