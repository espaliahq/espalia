# frozen_string_literal: true

namespace :assessments do
  desc "Seed realistic population-wide assessment activity for calibration demos (development only)"
  task seed_calibration_activity: :environment do
    # Demo ratings across an entire org must never touch production —
    # hard abort rather than a silent skip so a misconfigured invocation
    # is loud.
    abort "assessments:seed_calibration_activity is development-only." unless Rails.env.development?

    require "digest"

    slug = ENV["SEED_TENANT_SLUG"] || "nullisland"
    tenant = Tenant.find_by(slug: slug)
    unless tenant
      puts "No #{slug} tenant — skipping calibration activity seed."
      next
    end

    ActsAsTenant.with_tenant(tenant) do
      framework = FrameworkState::Framework.first
      cycle = framework && AssessmentCycle.for_framework(framework.framework_id).open_cycles.first
      unless framework && cycle
        puts "No framework/open cycle — skipping calibration activity seed."
        next
      end

      # ── Deterministic "randomness" ──
      # Every quantity derives from a SHA-256 hash of stable ids, so
      # re-running the seed converges instead of re-rolling the org, and
      # per-cell idempotency checks stay meaningful across runs. Bump the
      # version prefix to reshuffle the whole org's demo personas.
      weight = ->(*parts) do
        Digest::SHA256.hexdigest([ "calib-seed-v1", *parts ].join("/"))[0, 8].to_i(16) / 4294967295.0
      end

      frequencies = AssessmentLevelRating::FREQUENCIES # none some occasional consistent
      to_frequency = ->(value) { frequencies[value.round.clamp(0, 3)] }

      # The realism model (all deterministic per person/rater/capability):
      # - each RATER carries a persona offset in [-0.75, +0.75] — the
      #   lenient/harsh spread the tendency strip exists to surface;
      # - ~20% of capabilities are "ambiguous": each rater additionally
      #   swings up to ±1.1 bands on them — the unclear-expectation signal
      #   the divergence board should flag;
      # - each PERSON has a base competence in [1.1, 2.6] plus per-cell
      #   noise (±0.45) so teams aren't uniform;
      # - SELF ratings skew optimistic (persona bias +0.15..+0.65) and
      #   cover ~78% of cells; manager coverage is ~90% — the gaps are
      #   data (readiness bars, hollow dots);
      # - ~18% of manager-rated cells get a piece of linked evidence whose
      #   valence tracks the rating, so drill-in cards and backing stats
      #   have substance.
      ambiguous = ->(stable_id) { weight.("ambiguous", stable_id) < 0.2 }

      enrollments = AssessmentCycleEnrollment.active
        .where(cycle_id: cycle.cycle_id)
        .where.not(level_ordinal: nil)
        .where.not(role_id: nil)
        .to_a
      people = Person.where(id: enrollments.map(&:person_id)).index_by(&:id)
      # Alignment freezes an assessment's ratings, so writing more would only fail.
      aligned = AssessmentCycleProgress.where(cycle_id: cycle.cycle_id, status: %w[aligning aligned])
        .pluck(:person_id).to_set

      bindings_by_role = FrameworkState::CapabilityRoleBinding
        .includes(:capability)
        .group_by(&:role_id)
      expectation_cells = FrameworkState::BehaviouralExpectation
        .pluck(:capability_id, :level_ordinal).to_set

      manager_rated = AssessmentLevelRating.across_all_roles.for_cycle(cycle.cycle_id)
        .where.not(manager_rated_frequency: nil)
        .pluck(:person_id, :capability_stable_id, :level_ordinal).to_set
      self_rated = AssessmentLevelRating.across_all_roles.for_cycle(cycle.cycle_id)
        .where.not(self_rated_frequency: nil)
        .pluck(:person_id, :capability_stable_id, :level_ordinal).to_set

      evidence_templates = {
        "strongly_demonstrated" => "Drove the %<capability>s work for the team this quarter — set the approach, brought others along, and the results held up under review.",
        "demonstrated" => "Solid, repeated examples of %<capability>s — most recently on the quarterly planning work, where the follow-through was exactly what the level asks for.",
        "growth_area" => "Some good instincts on %<capability>s, but it still needs prompting — we agreed to make this the focus area for next quarter.",
        "significant_growth_area" => "Struggled with %<capability>s on the last two projects; we've set up pairing and a check-in cadence to build the muscle."
      }.freeze
      valence_for = ->(value) do
        case value
        when 2.4.. then "strongly_demonstrated"
        when 1.7...2.4 then "demonstrated"
        when 0.9...1.7 then "growth_area"
        else "significant_growth_area"
        end
      end

      handler = PersonDevelopment::CommandHandler.new
      stats = Hash.new(0)
      errors = []

      enrollments.each_with_index do |enrollment, index|
        person = people[enrollment.person_id]
        next stats[:skipped_no_person] += 1 unless person
        next stats[:skipped_aligned] += 1 if aligned.include?(person.id)

        rater_id = RecordedReportingManager.manager_id_for(person.id, framework.framework_id) ||
                   person.manager_id
        next stats[:skipped_no_manager] += 1 unless rater_id

        capabilities = (bindings_by_role[enrollment.role_id] || [])
          .filter_map(&:capability)
          .select do |cap|
            cap.status == "active" &&
              expectation_cells.include?([ cap.capability_id, enrollment.level_ordinal ])
          end
        next stats[:skipped_no_capabilities] += 1 if capabilities.empty?

        base = 1.1 + weight.("base", person.id) * 1.5
        rater_offset = weight.("rater-offset", rater_id) * 1.5 - 0.75
        self_bias = 0.15 + weight.("self-bias", person.id) * 0.5
        # Carriage is drawn per RATER, not per cell. Per-cell (~15% each)
        # had two bad effects: LevelCoverage excludes seeded values, so a
        # single carried cell makes a person permanently not manager-complete
        # — the readiness bars this demo also relies on emptied out — and an
        # ALL-carried rater became statistically unreachable (0.15^C), which
        # is the state the "all N" / "· all carried" copy exists to show.
        # One rater in ~6 now coasts entirely on last cycle, which also
        # demos the point that a coasting rater still carries their tendency
        # and self-gap flags.
        rater_coasting = weight.("coasting-rater", rater_id) < 0.17
        # The org's high performers (top ~30% by base competence) earn
        # genuine ABOVE-level surplus. Without this nobody can read "above
        # expectations": every rating sits at the enrolled level, so
        # performance never exceeds 100% and the cohort why-panel's
        # positive-only "Pulling it up" column is empty by construction.
        # Conditioning on base keeps it coherent — the same people whose
        # at-level cells rated near-consistent are the ones overreaching —
        # and makes >100% dots actually occur (an independent star draw
        # mostly handed surplus to people whose at-level deficits swallowed
        # it). Stars under a coasting rater are skipped — a fresh human
        # above-level rating would break that rater's "all carried" story.
        star = !rater_coasting && base > 2.15

        capabilities.each do |cap|
          cell_key = [ person.id, cap.stable_id, enrollment.level_ordinal ]
          swing = ambiguous.(cap.stable_id) ? weight.("swing", rater_id, cap.stable_id) * 2.2 - 1.1 : 0.0
          noise = weight.("noise", person.id, cap.stable_id) * 0.9 - 0.45
          value = (base + rater_offset + swing + noise).clamp(0.0, 3.0)

          begin
            # Manager rating (~90% coverage; the gaps feed readiness bars
            # and hollow "what did you see?" moments).
            if !manager_rated.include?(cell_key) && weight.("cover", person.id, cap.stable_id) >= 0.1
              # A coasting rater's cells all arrive CARRIED (seeded from a
              # prior cycle, unconfirmed), so every carried marker is
              # demo-able: the dashed dot, the strip's "all N" Carried cell,
              # the divergence row's carried note, the wall's dashed Mgr
              # stamp, and the session page's "To confirm".
              # A real seed writes source: "seeded" (ADR-20), so this is the
              # genuine event, not a patched read model.
              carried = rater_coasting
              handler.rate_as_manager(
                person.id, framework.framework_id, cap.stable_id,
                level_ordinal: enrollment.level_ordinal,
                frequency: to_frequency.(value),
                cycle_id: cycle.cycle_id,
                rated_by_id: rater_id,
                source: carried ? "seeded" : "human"
              )
              stats[:manager_ratings] += 1
              stats[:carried_ratings] += 1 if carried

              seed_calibration_evidence = weight.("evidence", person.id, cap.stable_id) < 0.18
              if seed_calibration_evidence
                title = "Calibration demo — #{cap.name} (#{person.name})"
                unless EvidenceItem.for_person(person.id)
                    .for_framework(framework.framework_id).where(title: title).exists?
                  valence = valence_for.(value)
                  handler.record_evidence(
                    person.id, framework.framework_id, SecureRandom.uuid_v7,
                    capability_stable_id: cap.stable_id,
                    level_ordinal: enrollment.level_ordinal,
                    source: "manager",
                    evidence_type: weight.("etype", person.id, cap.stable_id) < 0.5 ? "project_outcome" : "peer_feedback",
                    title: title,
                    content: format(evidence_templates.fetch(valence), capability: cap.name),
                    author_id: rater_id,
                    valence: valence
                  )
                  stats[:evidence_items] += 1
                end
              end
            end

            # Above-level surplus for stars: consistent-ish at L+1 on ~60%
            # of behaviours that have an expectation there → positive
            # contributions, >100% scores, a populated strongest column.
            if star && expectation_cells.include?([ cap.capability_id, enrollment.level_ordinal + 1 ])
              above_key = [ person.id, cap.stable_id, enrollment.level_ordinal + 1 ]
              if !manager_rated.include?(above_key) && weight.("above-cover", person.id, cap.stable_id) < 0.6
                above_value = (2.1 + weight.("above", person.id, cap.stable_id) * 0.9).clamp(0.0, 3.0)
                handler.rate_as_manager(
                  person.id, framework.framework_id, cap.stable_id,
                  level_ordinal: enrollment.level_ordinal + 1,
                  frequency: to_frequency.(above_value),
                  cycle_id: cycle.cycle_id,
                  rated_by_id: rater_id,
                  source: "human"
                )
                stats[:above_level_ratings] += 1
              end
            end

            # Self rating (~78% coverage, optimism bias).
            if !self_rated.include?(cell_key) && weight.("self-cover", person.id, cap.stable_id) < 0.78
              self_value = (base + self_bias + weight.("self-noise", person.id, cap.stable_id) * 0.8 - 0.4)
                .clamp(0.0, 3.0)
              handler.rate_self(
                person.id, framework.framework_id, cap.stable_id,
                level_ordinal: enrollment.level_ordinal,
                frequency: to_frequency.(self_value),
                cycle_id: cycle.cycle_id
              )
              stats[:self_ratings] += 1
            end
          rescue RuntimeError => e
            errors << "#{person.name} / #{cap.name}: #{e.message}"
          end
        end

        puts "  ...#{index + 1}/#{enrollments.size} people processed" if ((index + 1) % 15).zero?
      end

      # The single-cycle population above is only the starting state: the
      # carried vocabulary is a claim about a PREVIOUS cycle, so advance the
      # tenant through a couple more and let cross-cycle seeding carry the
      # values for real.
      require_relative "calibration_history_seed"
      history = CalibrationHistorySeed.new(tenant: tenant, framework: framework).call

      puts "Calibration activity seed complete for '#{cycle.name}':"
      puts "  Manager ratings: #{stats[:manager_ratings]} " \
           "(#{stats[:carried_ratings]} carried forward, " \
           "#{stats[:above_level_ratings]} above-level for the stars), " \
           "self ratings: #{stats[:self_ratings]}, evidence items: #{stats[:evidence_items]}"
      skipped = stats.slice(:skipped_no_person, :skipped_aligned, :skipped_no_manager, :skipped_no_capabilities)
      puts "  Skipped: #{skipped.map { |k, v| "#{k}=#{v}" }.join(', ')}" if skipped.values.sum.positive?
      if history.any?
        puts "  History: #{history[:cycles_opened]} further cycle(s) opened, " \
             "#{history[:reporting_moves]} reporting-line move(s); raters " \
             "#{history[:raters_vetting_fully]} vetting fully / " \
             "#{history[:raters_vetting_partly]} partly / " \
             "#{history[:raters_coasting]} coasting " \
             "(#{history[:ratings_confirmed]} confirmed, #{history[:ratings_revised]} revised)"
      end
      if errors.any?
        puts "  #{errors.size} cells skipped with errors (first 5):"
        errors.first(5).each { |line| puts "    #{line}" }
      end
    end
  end
end
