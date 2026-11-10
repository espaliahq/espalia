# frozen_string_literal: true

# Advances a dev tenant through a sequence of assessment cycles so the
# calibration surfaces have a HISTORY, not a single snapshot.
#
# The single-cycle seed could only fake carried ratings by writing
# `source: "seeded"` directly. Everything the carried vocabulary exists to
# show — the dashed pill, the strip's Carried column, "To confirm", the
# divergence row's carried note — is really a statement about the PREVIOUS
# cycle, so it deserves a previous cycle. Here each cycle is closed and the
# next one enrolled, which makes ADR-20's cross-cycle seeding do the
# carrying for real: same events, same provenance, same read models a
# production tenant would have.
#
# Three things the room needs to see, all deterministic per person/rater so
# re-running converges instead of re-rolling the org:
#
# - **Raters who vet and raters who coast.** A third confirm every carried
#   value (some revising as they go), a third get part-way, a third leave
#   the whole row inherited. That spread is the Carried column's whole point.
# - **Managers who move.** A slice of each cycle's population changes rater
#   between cycles — always to a sibling under the same department head, the
#   realistic re-org, and recorded on the PersonDevelopment stream so
#   `RecordedReportingManager` (not the live org chart) is what the drill-in
#   attributes by.
# - **Some genuinely new work**, so a later cycle isn't purely inherited.
#
# Development/test data only — the rake task guards the environment; this
# class takes whatever tenant it is handed.
class CalibrationHistorySeed
  # Cycles to advance THROUGH, in order, after whatever open cycle the
  # tenant already has. Each is created only if absent, so re-running the
  # seed converges on this history rather than growing it.
  FUTURE_CYCLES = [ "Q2 2026 Review", "Q3 2026 Review" ].freeze

  # Share of each cycle's population that changes rater before the next one.
  # Taken by RANK, like the personas below: an independent draw per person
  # can move nobody at all, and a demo tenant where reporting lines never
  # change cannot show what recorded-vs-live attribution is for.
  MOVER_SHARE = 0.12

  # Rater personas for the newly-carried cycle, assigned by RANK rather
  # than by an independent draw per rater: ranking guarantees all three
  # states appear whenever there are three or more raters, where independent
  # draws can leave a small tenant entirely coasting — which is exactly the
  # demo the Carried column can't make.
  PERSONA_SHARES = { fully: 0.34, partly: 0.67 }.freeze

  # Of the cells a vetting rater touches, how many they actually CHANGE
  # rather than confirm as-is.
  REVISION_SHARE = 0.25

  # @param tenant [Tenant]
  # @param framework [FrameworkState::Framework]
  # @param io [IO] progress sink
  def initialize(tenant:, framework:, io: $stdout)
    @tenant = tenant
    @framework = framework
    @io = io
    @cycles = AssessmentCycles::CommandHandler.new
    @development = PersonDevelopment::CommandHandler.new
    @stats = Hash.new(0)
  end

  # @return [Hash] counters for the task's summary line
  def call
    FUTURE_CYCLES.each do |name|
      # Scoped to the framework, like every other cycle query here: a
      # same-named cycle on another of the tenant's frameworks is not this
      # history, and would skip the advance while reporting it as done.
      if AssessmentCycle.for_framework(@framework.framework_id).find_by(name: name)
        @io.puts "  '#{name}' already exists — skipping."
        next
      end

      open_cycle = AssessmentCycle.for_framework(@framework.framework_id).open_cycles.first
      unless open_cycle
        @io.puts "  No open cycle to advance from — skipping '#{name}'."
        next
      end

      advance(from: open_cycle, to: name)
    end

    seed_session
    @stats
  end

  private

  # A live session on the current cycle. Without one, every visual check and
  # demo of this feature starts by hand-rolling a session that satisfies the
  # population rules — which is a tax, and one nobody pays correctly the
  # first time.
  def seed_session
    cycle = AssessmentCycle.for_framework(@framework.framework_id).open_cycles.first
    return unless cycle
    return if CalibrationSession.where(cycle_id: cycle.cycle_id).exists?

    facilitator = Person.find_by(id: facilitator_id)
    # A tenant with no root person (every Person has a manager) leaves us no
    # facilitator; without this the nil reaches `all_reports` and the
    # NoMethodError escapes the RuntimeError rescue below, killing the run.
    return @io.puts "  No root person to facilitate — skipping the demo session." unless facilitator

    raters, calibrants = room_for(cycle, facilitator)
    return @io.puts "  No rater with enrolled reports — skipping the demo session." if raters.empty?

    session_id = SecureRandom.uuid_v7
    handler = AssessmentCycles::CalibrationCommandHandler.new
    handler.define_session(
      session_id, cycle.cycle_id, @framework.framework_id,
      "#{cycle.name} calibration", @framework.current_published_version,
      facilitator_id: facilitator.id, participant_ids: raters.map(&:id),
      calibrant_person_ids: calibrants
    )
    handler.start_session(session_id, started_by_id: facilitator.id)
    @stats[:sessions_started] += 1
    @io.puts "  Live session: /calibration_sessions/#{session_id}"
  rescue RuntimeError => e
    @io.puts "  Demo session skipped: #{e.message}"
  end

  # Raters under the facilitator who have enrolled reports, and those
  # reports — the population rules in miniature: a rater is never their own
  # calibrant, and the facilitator is never in the room's population.
  def room_for(cycle, facilitator)
    enrolled = AssessmentCycleEnrollment.active
      .where(cycle_id: cycle.cycle_id).pluck(:person_id).to_set
    subtree = facilitator.all_reports.to_a
    by_manager = subtree.select { |person| enrolled.include?(person.id) }.group_by(&:manager_id)

    raters = subtree.select { |person| by_manager.key?(person.id) && person.id != facilitator.id }
    rater_ids = raters.map(&:id)
    calibrants = rater_ids.flat_map { |id| by_manager[id].map(&:id) } - rater_ids - [ facilitator.id ]

    [ raters, calibrants ]
  end

  def advance(from:, to:)
    @io.puts "  Closing '#{from.name}' and opening '#{to}'…"
    @cycles.close_cycle(from.cycle_id, closed_by: facilitator_id)
    @stats[:cycles_closed] += 1

    move_reporting_lines(from)

    cycle_id = SecureRandom.uuid_v7
    @cycles.define_cycle(
      cycle_id, @framework.framework_id, to, "regular",
      @framework.current_published_version, defined_by: facilitator_id
    )
    cycle = AssessmentCycle.find_by!(cycle_id: cycle_id)

    # The same path production uses: enrol + snapshot the role/level + seed
    # the prior cycle's ratings, one transaction per person.
    AssessmentCycles::BulkEnrollmentJob.perform_now(cycle, enrolled_by: facilitator_id)
    @stats[:cycles_opened] += 1

    vet_carried_ratings(cycle)
  end

  # A slice of the population changes rater between cycles — to a SIBLING
  # in the same department under the same manager-of-managers, which is the
  # re-org that actually happens and keeps everyone inside the facilitator's
  # scope.
  #
  # Both halves matter: the live org chart moves, and the fact is recorded
  # on the person's stream, because manager-rating authority reads the
  # recorded fact first (see authorization.md).
  def move_reporting_lines(cycle)
    movers(cycle).each do |person|
      sibling = sibling_rater_for(person)
      next unless sibling

      person.update!(manager_id: sibling.id)
      @development.record_reporting_manager(
        person.id, @framework.framework_id, sibling.id, source: "hris"
      )
      @stats[:reporting_moves] += 1
    end
  end

  # The population slice that changes rater this time — at least one whenever
  # there is anyone to move.
  def movers(cycle)
    people = population(cycle).sort_by { |person| weight("move", cycle.cycle_id, person.id) }
    return [] if people.empty?

    people.first([ (people.size * MOVER_SHARE).ceil, 1 ].max)
  end

  # Another rater in the same department, reporting to the same person as
  # this one's current rater. Without the department, a VP's only other
  # report takes everyone: the demo once moved every designer under an
  # engineering manager.
  def sibling_rater_for(person)
    current = person.manager
    return nil unless current&.manager_id

    # Ordered: an unordered read gives Postgres licence to return rows in a
    # different sequence per run, which would pick a different sibling and
    # break the convergence this class promises.
    candidates = Person.where(manager_id: current.manager_id, department: current.department)
      .where.not(id: current.id).order(:id).to_a
    return nil if candidates.empty?

    candidates[(weight("sibling", person.id) * candidates.size).floor.clamp(0, candidates.size - 1)]
  end

  # The carried values are now real; who confirms them is the demo.
  def vet_carried_ratings(cycle)
    by_rater = carried_by_rater(cycle)
    ranked = by_rater.keys.sort_by { |rater_id| weight("vets", cycle.cycle_id, rater_id) }

    ranked.each_with_index do |rater_id, index|
      position = (index + 0.5) / ranked.size
      case position
      when ...PERSONA_SHARES[:fully]  then vet(by_rater[rater_id], rater_id, cycle, 1.0, :raters_vetting_fully)
      when ...PERSONA_SHARES[:partly] then vet(by_rater[rater_id], rater_id, cycle, 0.5, :raters_vetting_partly)
      else                                 @stats[:raters_coasting] += 1
      end
    end
  end

  def vet(ratings, rater_id, cycle, share, counter)
    @stats[counter] += 1
    ratings.each do |rating|
      next unless share >= 1.0 || weight("vet-cell", rating.id) < share

      confirm_or_revise(rating, rater_id, cycle)
    end
  end

  # Confirming re-emits the SAME value as human — the product's "pick the
  # shown value to confirm it" gesture. A revision moves it a band, which is
  # what makes some rows change between cycles instead of freezing.
  def confirm_or_revise(rating, rater_id, cycle)
    frequencies = AssessmentLevelRating::FREQUENCIES
    current = frequencies.index(rating.manager_rated_frequency) || 0
    step = weight("direction", rating.id) < 0.5 ? -1 : 1
    value = if weight("revise", rating.id) < REVISION_SHARE
      (current + step).clamp(0, frequencies.size - 1)
    else
      current
    end
    # A revision off either end of the scale clamps back to where it was, so
    # it re-emits the same value — that is a confirmation, and counting it as
    # a revision overstates what the summary reports.
    revising = value != current

    @development.rate_as_manager(
      rating.person_id, @framework.framework_id, rating.capability_stable_id,
      level_ordinal: rating.level_ordinal,
      frequency: frequencies[value],
      cycle_id: cycle.cycle_id,
      rated_by_id: rater_id,
      source: "human"
    )
    @stats[revising ? :ratings_revised : :ratings_confirmed] += 1
  rescue RuntimeError => e
    @stats[:vet_errors] += 1
    @io.puts "    #{rating.person_id} / #{rating.capability_stable_id}: #{e.message}" if @stats[:vet_errors] < 4
  end

  # Carried manager ratings in this cycle, grouped by the rater who owns
  # them (recorded reporting manager first — the move above is exactly why
  # the live chart is not authoritative here).
  def carried_by_rater(cycle)
    ratings = AssessmentLevelRating.across_all_roles.for_cycle(cycle.cycle_id)
      .where(manager_rating_source: "seeded")
      .where.not(manager_rated_frequency: nil)
      .to_a
    recorded = RecordedReportingManager
      .where(framework_id: @framework.framework_id, person_id: ratings.map(&:person_id).uniq)
      .pluck(:person_id, :manager_id).to_h
    live = Person.where(id: ratings.map(&:person_id).uniq).pluck(:id, :manager_id).to_h

    ratings.group_by { |r| recorded[r.person_id] || live[r.person_id] }.except(nil)
  end

  def population(cycle)
    Person.where(
      id: AssessmentCycleEnrollment.active.where(cycle_id: cycle.cycle_id).select(:person_id)
    ).to_a
  end

  # Whoever defined the tenant's first cycle stands in as the actor.
  def facilitator_id
    @facilitator_id ||= Person.joins(:tenant).where(tenant: @tenant, manager_id: nil).first&.id
  end

  # Deterministic 0…1 from stable ids — the same trick the population seed
  # uses, so a re-run converges instead of re-rolling every persona.
  def weight(*parts)
    Digest::SHA256.hexdigest([ "calib-history-v1", *parts ].join("/"))[0, 8].to_i(16) / 4294967295.0
  end
end
