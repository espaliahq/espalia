# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new
    @cycle_handler = AssessmentCycles::CommandHandler.new

    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "full assessment cycle via cycle handler + rating handler" do
    should "support define+enroll, rate, revise, conclude" do
      # Assign person to framework
      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      # Define and enroll in a cycle — the sync handler propagates to the person stream
      cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @cycle_handler.enroll(cycle_id, @person_id)

      # Self-rate a capability at level 3
      cap_sid = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "consistent", cycle_id: cycle_id, comment: "I'm here")

      # Verify assessment level rating projection
      rating = AssessmentLevelRating.find_by(
        cycle_id: cycle_id,
        person_id: @person_id,
        framework_id: @framework_id,
        capability_stable_id: cap_sid,
        level_ordinal: 3
      )
      assert_not_nil rating
      assert_equal "consistent", rating.self_rated_frequency
      assert_equal cycle_id, rating.cycle_id

      # Revise the rating
      @handler.revise_self_rating(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "occasional", rationale: "On reflection", cycle_id: cycle_id)

      rating.reload
      assert_equal "occasional", rating.self_rated_frequency

      # Close the cycle — the participation concludes (not a leave/removal)
      @cycle_handler.close_cycle(cycle_id)

      # Verify the PersonDev stream contains the expected events
      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      assert_equal 5, events.length
      assert_kind_of PersonDevelopment::Events::PersonAssignedToFramework, events[0]
      assert_kind_of PersonDevelopment::Events::JoinedAssessmentCycle, events[1]
      assert_kind_of PersonDevelopment::Events::SelfRated, events[2]
      assert_kind_of PersonDevelopment::Events::SelfRatingRevised, events[3]
      assert_kind_of PersonDevelopment::Events::AssessmentCycleConcluded, events[4]
    end
  end

  context "manager rating flow" do
    should "support rate_as_manager, revise_manager_rating, and align_assessment" do
      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(cycle_id, @framework_id, "Q1 2026", "regular", 1)
      @cycle_handler.enroll(cycle_id, @person_id)

      cap_sid = SecureRandom.uuid_v7

      # Manager rates
      @handler.rate_as_manager(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "some", cycle_id: cycle_id, comment: "Room to grow")

      rating = AssessmentLevelRating.find_by(
        cycle_id: cycle_id,
        person_id: @person_id,
        framework_id: @framework_id,
        capability_stable_id: cap_sid,
        level_ordinal: 3
      )
      assert_not_nil rating
      assert_equal "some", rating.manager_rated_frequency
      assert_equal "Room to grow", rating.manager_rated_comment

      # Manager revises
      @handler.revise_manager_rating(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, frequency: "occasional", rationale: "Saw improvement", cycle_id: cycle_id)

      rating.reload
      assert_equal "occasional", rating.manager_rated_frequency

      # Manager starts alignment, then aligns
      manager = create(:person, tenant: @tenant, name: "Mgr")
      @handler.start_alignment(@person_id, @framework_id, cycle_id,
        started_by_id: manager.id, cell_keys: [ [ cap_sid, 3 ] ])
      @handler.align_assessment(@person_id, @framework_id, cap_sid,
        level_ordinal: 3, aligned_frequency: "occasional", cycle_id: cycle_id,
        comment: "Agreed on occasional")

      rating.reload
      assert_equal "occasional", rating.aligned_frequency
      assert_equal "Agreed on occasional", rating.aligned_comment

      # Verify stream
      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      rating_events = events.select do |e|
        e.is_a?(PersonDevelopment::Events::ManagerRated) ||
          e.is_a?(PersonDevelopment::Events::ManagerRatingRevised) ||
          e.is_a?(PersonDevelopment::Events::AssessmentAligned)
      end
      assert_equal 3, rating_events.length
    end
  end

  context "re-enrolling into the same cycle after unenroll" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant, name: "Mgr")
        @assessee = create(:person, tenant: @tenant, name: "Assessee")
      end
      @person_id = @assessee.id

      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1,
        defined_by: @manager.id)
      @cycle_handler.enroll(@cycle_id, @person_id, enrolled_by: @manager.id)

      # Build state in the original enrolment: rate, start alignment, then unenroll.
      @cap_sid = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, @cap_sid,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
      @handler.rate_as_manager(@person_id, @framework_id, @cap_sid,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id)
      @cycle_handler.unenroll(@cycle_id, @person_id, "manual", unenrolled_by: @manager.id)

      # Re-enroll into the SAME cycle.
      @cycle_handler.enroll(@cycle_id, @person_id, enrolled_by: @manager.id)
    end

    should "let the person rate again without raising about a missing prior rating" do
      assert_nothing_raised do
        @handler.rate_self(@person_id, @framework_id, @cap_sid,
          level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id)
      end

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: @cap_sid, level_ordinal: 2
        )
        assert_equal "occasional", rating.self_rated_frequency
        # Stale aligned/manager values from the prior enrolment must be gone.
        assert_nil rating.manager_rated_frequency
        assert_nil rating.aligned_frequency
      end
    end

    should "reset the participant's alignment lifecycle columns on re-enrol" do
      ActsAsTenant.with_tenant(@tenant) do
        participation = AssessmentCycleParticipation.find_by(
          cycle_id: @cycle_id, person_id: @person_id
        )
        # Enrollment side: back to "enrolled"
        assert_equal "enrolled", participation.enrollment.status
        # Progress side: re-init to in_progress, all journey columns nil
        assert_equal "in_progress", participation.progress.status
        assert_nil participation.progress.started_at
        assert_nil participation.progress.alignment_started_at
        assert_nil participation.progress.alignment_started_by_id
        assert_nil participation.progress.aligned_at
        assert_nil participation.progress.aligned_by_id
      end
    end
  end

  context "#start_alignment auto-alignment" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant, name: "Mgr")
        @assessee = create(:person, tenant: @tenant, name: "Assessee")
      end
      @person_id = @assessee.id

      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1,
        defined_by: @manager.id)
      @cycle_handler.enroll(@cycle_id, @person_id, enrolled_by: @manager.id)
    end

    should "emit AssessmentAligned for cells where self and manager match" do
      cap_a = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_a,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
      @handler.rate_as_manager(@person_id, @framework_id, cap_a,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)

      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id,
        cell_keys: rated_cells)

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      aligned_events = events.grep(PersonDevelopment::Events::AssessmentAligned)

      assert_equal 1, aligned_events.length
      e = aligned_events.first
      assert_equal cap_a, e.data[:capability_stable_id]
      assert_equal 2, e.data[:level_ordinal]
      assert_equal "consistent", e.data[:aligned_frequency]
      assert_match(/Auto-aligned/, e.data[:comment])

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_a, level_ordinal: 2
        )
        assert_equal "consistent", rating.aligned_frequency
      end
    end

    should "NOT auto-align carried (seeded) agreement — carried values are unvetted" do
      cap_seeded = SecureRandom.uuid_v7
      seed_source_cycle = SecureRandom.uuid_v7
      # ADR-20 seeds both sides of a previously-agreed cell with equal
      # values — deliberate agreement LAST cycle, not this one.
      @handler.rate_self(@person_id, @framework_id, cap_seeded,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id,
        comment: "Seeded from prior cycle", source: "seeded", seeded_from_cycle_id: seed_source_cycle)
      @handler.rate_as_manager(@person_id, @framework_id, cap_seeded,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id,
        comment: "Seeded from prior cycle", source: "seeded", seeded_from_cycle_id: seed_source_cycle)
      # A second cell where the manager CONFIRMED their side but self is
      # still carried — one unvetted side is enough to hold the cell open.
      cap_half = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_half,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id,
        comment: "Seeded from prior cycle", source: "seeded", seeded_from_cycle_id: seed_source_cycle)
      @handler.rate_as_manager(@person_id, @framework_id, cap_half,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id,
        comment: "Seeded from prior cycle", source: "seeded", seeded_from_cycle_id: seed_source_cycle)
      @handler.revise_manager_rating(@person_id, @framework_id, cap_half,
        level_ordinal: 2, frequency: "consistent", rationale: "Confirmed carried-forward rating",
        cycle_id: @cycle_id, rated_by_id: @manager.id)
      # And one where BOTH sides were confirmed — that one auto-aligns.
      cap_vetted = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_vetted,
        level_ordinal: 2, frequency: "some", cycle_id: @cycle_id)
      @handler.rate_as_manager(@person_id, @framework_id, cap_vetted,
        level_ordinal: 2, frequency: "some", cycle_id: @cycle_id, rated_by_id: @manager.id)

      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id,
        cell_keys: rated_cells)

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      aligned = Rails.configuration.event_store.read.stream(stream).to_a
        .grep(PersonDevelopment::Events::AssessmentAligned)
      assert_equal [ cap_vetted ], aligned.map { |e| e.data[:capability_stable_id] },
        "only the fully-vetted agreement may formalise at start; carried cells stay open for the conversation"
    end

    should "NOT auto-align when self and manager differ" do
      cap_b = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_b,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id)
      @handler.rate_as_manager(@person_id, @framework_id, cap_b,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)

      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id,
        cell_keys: rated_cells)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_b, level_ordinal: 2
        )
        assert_nil rating.aligned_frequency
      end
    end

    should "NOT auto-align when only one party rated" do
      cap_c = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_c,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)

      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id,
        cell_keys: rated_cells)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_c, level_ordinal: 2
        )
        assert_not_nil rating, "expected the self-rated row to exist after start_alignment"
        assert_nil rating.aligned_frequency
      end
    end

    should "NOT auto-align cells where neither party rated (no row exists)" do
      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id,
        cell_keys: rated_cells)

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      aligned_events = events.grep(PersonDevelopment::Events::AssessmentAligned)
      assert_empty aligned_events
    end

    should "auto-align matching 'none' values (none is a deliberate rating)" do
      cap_d = SecureRandom.uuid_v7
      @handler.rate_self(@person_id, @framework_id, cap_d,
        level_ordinal: 1, frequency: "none", cycle_id: @cycle_id)
      @handler.rate_as_manager(@person_id, @framework_id, cap_d,
        level_ordinal: 1, frequency: "none", cycle_id: @cycle_id)

      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id,
        cell_keys: rated_cells)

      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @person_id,
          capability_stable_id: cap_d, level_ordinal: 1
        )
        assert_equal "none", rating.aligned_frequency
      end
    end

    should "emit start_alignment + N AssessmentAligned events in a single transaction" do
      cap_e = SecureRandom.uuid_v7
      cap_f = SecureRandom.uuid_v7
      [ cap_e, cap_f ].each do |cap|
        @handler.rate_self(@person_id, @framework_id, cap,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
        @handler.rate_as_manager(@person_id, @framework_id, cap,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
      end

      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id,
        cell_keys: rated_cells)

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a

      start_idx = events.index { |e| e.is_a?(PersonDevelopment::Events::AlignmentStarted) }
      assert_not_nil start_idx, "expected AlignmentStarted on stream"

      auto_aligned = events[(start_idx + 1)..]
        .take_while { |e| e.is_a?(PersonDevelopment::Events::AssessmentAligned) }
      assert_equal 2, auto_aligned.length
    end
  end

  context "#reopen_alignment" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant, name: "Mgr")
        @assessee = create(:person, tenant: @tenant, name: "Assessee")
      end
      @person_id = @assessee.id

      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1,
        defined_by: @manager.id)
      @cycle_handler.enroll(@cycle_id, @person_id, enrolled_by: @manager.id)
      @handler.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: @manager.id)
      @handler.complete_alignment(@person_id, @framework_id, @cycle_id, completed_by_id: @manager.id)
    end

    should "land an AlignmentReopened event on the person-development stream" do
      @handler.reopen_alignment(@person_id, @framework_id, @cycle_id, reopened_by_id: @manager.id)

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      event = Rails.configuration.event_store.read.stream(stream).to_a
        .grep(PersonDevelopment::Events::AlignmentReopened).last
      assert_not_nil event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @manager.id, event.data[:reopened_by_id]
    end

    should "allow the manager to re-complete after re-opening" do
      @handler.reopen_alignment(@person_id, @framework_id, @cycle_id, reopened_by_id: @manager.id)

      assert_nothing_raised do
        @handler.complete_alignment(@person_id, @framework_id, @cycle_id, completed_by_id: @manager.id)
      end
    end
  end

  context "#seed_ratings_from_prior_cycle" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        # Build a real framework + capability so the stable_id lookup matches.
        @framework = create(:framework_state, framework_id: @framework_id, name: "FW")
        rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
        @role = create(:framework_role, role_family_id: rf.role_family_id,
          name: "SE", code: "E", track: "ic")
        @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
        cat = create(:framework_capability_category, framework_id: @framework_id,
          name: "Thinking", ordinal: 1)
        @cap_stable_id = SecureRandom.uuid_v7
        @cap = create(:framework_capability, category_id: cat.category_id,
          name: "Critical Thinking", stable_id: @cap_stable_id)
        create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: @role.role_id)
        create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2)

        # Real Person records — required by FK on assessment_cycle_progress
        # for alignment_started_by_id / aligned_by_id.
        @assessee = create(:person, tenant: @tenant, name: "Assessee")
        @manager = create(:person, tenant: @tenant, name: "Mgr")
      end

      @person_id = @assessee.id

      @handler.assign_to_framework(@person_id, @framework_id, @role.role_id, @level.level_id)

      # Build a prior cycle that completed alignment with one aligned value.
      @prior_cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(@prior_cycle_id, @framework_id, "Q1 2026", "regular", 1,
        defined_by: @manager.id)
      @cycle_handler.enroll(@prior_cycle_id, @person_id, enrolled_by: @manager.id)
      @handler.rate_self(@person_id, @framework_id, @cap_stable_id,
        level_ordinal: 2, frequency: "occasional", cycle_id: @prior_cycle_id)
      @handler.start_alignment(@person_id, @framework_id, @prior_cycle_id, started_by_id: @manager.id)
      @handler.align_assessment(@person_id, @framework_id, @cap_stable_id,
        level_ordinal: 2, aligned_frequency: "consistent", cycle_id: @prior_cycle_id)
      @handler.complete_alignment(@person_id, @framework_id, @prior_cycle_id, completed_by_id: @manager.id)

      # Close the prior cycle (which leaves all participants) so a new one can open.
      @cycle_handler.close_cycle(@prior_cycle_id, closed_by: @manager.id)

      @new_cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(@new_cycle_id, @framework_id, "Q2 2026", "regular", 1,
        defined_by: @manager.id)
      @cycle_handler.enroll(@new_cycle_id, @person_id, enrolled_by: @manager.id)
    end

    should "auto-seed both perspectives in the new cycle from prior aligned values" do
      # The PersonEnrollmentSync handler should have already seeded as part of enrol.
      ActsAsTenant.with_tenant(@tenant) do
        rating = AssessmentLevelRating.find_by(
          cycle_id: @new_cycle_id, person_id: @person_id,
          capability_stable_id: @cap_stable_id, level_ordinal: 2
        )
        assert_not_nil rating
        assert_equal "consistent", rating.self_rated_frequency
        assert_equal "consistent", rating.manager_rated_frequency
        assert_equal "seeded", rating.source
        assert_equal @prior_cycle_id, rating.seeded_from_cycle_id
      end
    end

    should "leave participant status at :enrolled because seeded events do not start the cycle" do
      ActsAsTenant.with_tenant(@tenant) do
        participation = AssessmentCycleParticipation.find_by(
          cycle_id: @new_cycle_id, person_id: @person_id
        )
        assert_equal "enrolled", participation.status
        assert_nil participation.started_at
      end
    end

    should "be idempotent — re-running the seed does not duplicate events on the new cycle" do
      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events_before = Rails.configuration.event_store.read.stream(stream).to_a
      seed_event_count = events_before.grep(PersonDevelopment::Events::SelfRated)
        .count { |e| e.data[:source] == "seeded" && e.data[:cycle_id] == @new_cycle_id }

      result = @handler.seed_ratings_from_prior_cycle(
        @person_id, @framework_id, @new_cycle_id, @prior_cycle_id,
        seeded_by_id: @manager.id
      )
      assert_equal 0, result[:seeded], "expected no new seed events on a re-run"

      events_after = Rails.configuration.event_store.read.stream(stream).to_a
      reseeded = events_after.grep(PersonDevelopment::Events::SelfRated)
        .count { |e| e.data[:source] == "seeded" && e.data[:cycle_id] == @new_cycle_id }
      assert_equal seed_event_count, reseeded, "re-running the seed must not append duplicate seeded SelfRated events"
    end

    should "carry forward unaligned ratings per perspective from the most recent prior cycle" do
      # A second capability rated ONE-sided in the new (Q2) cycle: the seed
      # into Q3 must carry only the side that existed.
      cap2_stable_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        cat = FrameworkState::CapabilityCategory.find_by!(framework_id: @framework_id)
        create(:framework_capability, category_id: cat.category_id,
          name: "Communication", stable_id: cap2_stable_id)
      end

      # In Q2 (never aligned): revise self on cap1 away from the seeded value,
      # and self-rate cap2 with no manager counterpart.
      @handler.revise_self_rating(@person_id, @framework_id, @cap_stable_id,
        level_ordinal: 2, frequency: "some", rationale: "changed my mind", cycle_id: @new_cycle_id)
      @handler.rate_self(@person_id, @framework_id, cap2_stable_id,
        level_ordinal: 2, frequency: "occasional", cycle_id: @new_cycle_id)

      @cycle_handler.close_cycle(@new_cycle_id, closed_by: @manager.id)
      q3_cycle_id = SecureRandom.uuid_v7
      @cycle_handler.define_cycle(q3_cycle_id, @framework_id, "Q3 2026", "regular", 1,
        defined_by: @manager.id)
      @cycle_handler.enroll(q3_cycle_id, @person_id, enrolled_by: @manager.id)

      ActsAsTenant.with_tenant(@tenant) do
        cap1 = AssessmentLevelRating.find_by!(cycle_id: q3_cycle_id, person_id: @person_id,
          capability_stable_id: @cap_stable_id, level_ordinal: 2)
        # Never agreed in Q2 → each side carries its own last value: the
        # revised self ("some"), the still-seeded manager ("consistent").
        assert_equal "some", cap1.self_rated_frequency
        assert_equal "consistent", cap1.manager_rated_frequency
        # Seeded from the most recent PARTICIPATION (unaligned Q2), not the
        # last aligned cycle (Q1) — the chain already carries Q1's baseline.
        assert_equal @new_cycle_id, cap1.seeded_from_cycle_id

        cap2 = AssessmentLevelRating.find_by!(cycle_id: q3_cycle_id, person_id: @person_id,
          capability_stable_id: cap2_stable_id, level_ordinal: 2)
        assert_equal "occasional", cap2.self_rated_frequency
        assert_nil cap2.manager_rated_frequency, "a side never rated must not be fabricated"
      end

      # Per-side idempotency: a re-run seeds nothing further.
      result = @handler.seed_ratings_from_prior_cycle(
        @person_id, @framework_id, q3_cycle_id, @new_cycle_id, seeded_by_id: @manager.id
      )
      assert_equal 0, result[:seeded]
    end

    should "emit a RatingSeedSkipped event for any prior aligned capability missing from the new framework" do
      # The setup seeded one capability successfully. Add a second prior-aligned
      # value whose stable_id does NOT exist in the current framework — the
      # seeder should land a RatingSeedSkipped audit event for it instead.
      orphan_stable_id = SecureRandom.uuid_v7

      # Inject the orphan rating directly into the prior cycle's projection — the
      # seeder reads from AssessmentLevelRating, so this is enough to simulate a
      # capability that existed in the prior framework version but not the new one.
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentLevelRating.create!(
          tenant: @tenant,
          cycle_id: @prior_cycle_id,
          person_id: @person_id,
          framework_id: @framework_id,
          capability_stable_id: orphan_stable_id,
          level_ordinal: 2,
          aligned_frequency: "occasional",
          source: "human",
          migration_status: "not_flagged"
        )
      end

      # Re-run the seed against the new cycle. The orphan should be skipped,
      # the existing one is already seeded so it'd revise — but the stream
      # check below only looks at the orphan.
      result = @handler.seed_ratings_from_prior_cycle(
        @person_id, @framework_id, @new_cycle_id, @prior_cycle_id,
        seeded_by_id: @manager.id
      )

      assert_operator result[:skipped].length, :>=, 1, "expected at least one skip"

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      skip_events = events.grep(PersonDevelopment::Events::RatingSeedSkipped)
      orphan_skip = skip_events.find { |e| e.data[:capability_stable_id] == orphan_stable_id }

      assert_not_nil orphan_skip, "expected a RatingSeedSkipped event for the orphan capability"
      assert_equal 2, orphan_skip.data[:level_ordinal]
      assert_equal "occasional", orphan_skip.data[:prior_aligned_frequency]
      assert_equal @new_cycle_id, orphan_skip.data[:current_cycle_id]
      assert_equal @prior_cycle_id, orphan_skip.data[:prior_cycle_id]
      assert_equal "capability_not_in_current_framework", orphan_skip.data[:reason]
    end
  end

  context "evidence flow" do
    setup do
      @handler.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @author = ActsAsTenant.with_tenant(@tenant) do
        create(:person, tenant: @tenant, name: "Evidence Author")
      end
      @author_id = @author.id
    end

    should "record, link, unlink, and withdraw evidence end-to-end" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7
      new_cap_sid = SecureRandom.uuid_v7

      @handler.record_evidence(@person_id, @framework_id, evidence_id,
        capability_stable_id: cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "Shipped X", author_id: @author_id,
        title: "Done", valence: "demonstrated")

      item = EvidenceItem.find(evidence_id)
      assert_equal "active", item.link_status
      assert_equal cap_sid, item.capability_stable_id
      assert_equal 3, item.level_ordinal
      assert_equal "self", item.source
      assert_equal "self", item.feedback_direction
      # The first link is materialised on EvidenceRecorded.
      assert_equal [ [ cap_sid, 3 ] ],
        EvidenceLink.active.where(evidence_id: evidence_id).pluck(:capability_stable_id, :level_ordinal)

      @handler.add_evidence_link(@person_id, @framework_id, evidence_id,
        capability_stable_id: new_cap_sid, level_ordinal: 4,
        linked_by_id: @author_id, rationale: "Also applies", valence: "demonstrated")

      assert_equal [ [ cap_sid, 3 ], [ new_cap_sid, 4 ] ],
        EvidenceLink.active.where(evidence_id: evidence_id).order(:linked_at)
          .pluck(:capability_stable_id, :level_ordinal)

      @handler.remove_evidence_link(@person_id, @framework_id, evidence_id,
        capability_stable_id: cap_sid, level_ordinal: 3,
        removed_by_id: @author_id, reason: "Mislinked")

      assert_equal [ [ new_cap_sid, 4 ] ],
        EvidenceLink.active.where(evidence_id: evidence_id).pluck(:capability_stable_id, :level_ordinal)

      @handler.withdraw_evidence(@person_id, @framework_id, evidence_id,
        withdrawn_by_id: @author_id, reason: "Wrong context")

      item.reload
      assert_equal "withdrawn", item.link_status
      assert_equal @author_id, item.withdrawn_by_id
      assert_equal "Wrong context", item.withdrawal_reason

      stream = EventStreamNaming.person_development_stream(@person_id, @framework_id)
      events = Rails.configuration.event_store.read.stream(stream).to_a
      kinds = events.map(&:class)
      assert_includes kinds, PersonDevelopment::Events::EvidenceRecorded
      assert_includes kinds, PersonDevelopment::Events::EvidenceLinkAdded
      assert_includes kinds, PersonDevelopment::Events::EvidenceLinkRemoved
      assert_includes kinds, PersonDevelopment::Events::EvidenceWithdrawn
    end

    should "persist upward feedback from a report to their manager" do
      manager = create(:person, tenant: @tenant, name: "Manager")
      report = create(:person, tenant: @tenant, manager: manager, name: "Report")
      evidence_id = SecureRandom.uuid_v7
      @handler.assign_to_framework(manager.id, @framework_id, @role_id, @level_id)

      @handler.record_evidence(manager.id, @framework_id, evidence_id,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, source: "peer",
        evidence_type: "peer_feedback", content: "Helpful leadership", author_id: report.id,
        valence: "demonstrated")

      assert_equal "report_to_manager", EvidenceItem.find(evidence_id).feedback_direction
    end

    should "round-trip an external_reference through the projection" do
      evidence_id = SecureRandom.uuid_v7
      @handler.record_evidence(@person_id, @framework_id, evidence_id,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, source: "manager",
        evidence_type: "code_review", content: "Reviewed PR", author_id: @author_id,
        external_reference: { system: "github", url: "https://github.com/o/r/pull/12" }, valence: "demonstrated")

      item = EvidenceItem.find(evidence_id)
      assert_equal "github", item.external_reference.system
      assert_equal "https://github.com/o/r/pull/12", item.external_reference.url
    end
  end

  private

  # Every cell this person rated in the cycle — the role scope these tests'
  # frameworkless fixtures would otherwise have to build.
  def rated_cells
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.across_all_roles.where(cycle_id: @cycle_id, person_id: @person_id)
        .pluck(:capability_stable_id, :level_ordinal)
    end
  end
end
