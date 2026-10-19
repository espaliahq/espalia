# frozen_string_literal: true

require "test_helper"

class Operations::CalibrationSessions::OperationsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    # Org: dept_head → { em_1 → report_1, em_2 → report_2 }; outsider is
    # outside the dept_head's subtree.
    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em_1 = create(:person, tenant: @tenant, name: "Mia Manager", manager: @dept_head)
    @em_2 = create(:person, tenant: @tenant, name: "Raj Rater", manager: @dept_head)
    @report_1 = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em_1)
    @report_2 = create(:person, tenant: @tenant, name: "Omar IC", manager: @em_2)
    @outsider = create(:person, tenant: @tenant, name: "Zoe Elsewhere")

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_version: 1, latest_framework_version: 2)
    @facilitator_context = context_for(@dept_head)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def context_for(person, role: :member)
    user = create(:user)
    tenant_user = create(:tenant_user, user: user, tenant: @tenant, role: role, person: person)
    AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person)
  end

  def define!(params = {})
    Operations::CalibrationSessions::Define.call(
      context: @facilitator_context,
      params: {
        cycle_id: @cycle.cycle_id,
        name: "Engineering calibration",
        participant_ids: [ @em_1.id, @em_2.id ],
        calibrant_person_ids: [ @report_1.id, @report_2.id ]
      }.merge(params)
    )
  end

  context "Define" do
    should "create a draft session with rosters and the cycle's latest framework version" do
      result = define!

      session = CalibrationSession.find(result[:session_id])
      assert_equal "draft", session.status
      assert_equal @cycle.cycle_id, session.cycle_id
      assert_equal @cycle.framework_id, session.framework_id
      assert_equal 2, session.framework_version, "snapshots the cycle's latest version"
      assert_equal @dept_head.id, session.facilitator_id
      assert_equal [ @em_1.id, @em_2.id ].sort, session.participants.pluck(:person_id).sort
      assert_equal [ @report_1.id, @report_2.id ].sort, session.calibrants.pluck(:person_id).sort
    end

    should "deny a manager of ICs only" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::Define.call(
          context: context_for(@em_1),
          params: { cycle_id: @cycle.cycle_id, name: "X", participant_ids: [ @report_1.id ] }
        )
      end
    end

    should "reject a calibrant outside the facilitator's org" do
      err = assert_raises(Operations::Base::ParameterError) do
        define!(calibrant_person_ids: [ @report_1.id, @outsider.id ])
      end
      assert_match(/not in the facilitator's org/, err.message)
      assert_match(@outsider.id, err.message)
    end

    should "accept an out-of-subtree calibrant a participant rates via delegation" do
      # The server's own seed includes delegation-sourced people from outside
      # the live subtree — the scope check must accept what the seed produces.
      seconded = create(:person, tenant: @tenant, name: "Sam Seconded")
      create(:person_framework_assignment, tenant: @tenant,
             person_id: seconded.id, framework_id: @cycle.framework_id)
      create(:manager_assessment_delegation, tenant: @tenant,
             person_id: seconded.id, framework_id: @cycle.framework_id,
             delegate_person_id: @em_1.id)

      result = define!(calibrant_person_ids: [ @report_1.id, seconded.id ])

      session = CalibrationSession.find(result[:session_id])
      assert_includes session.calibrants.pluck(:person_id), seconded.id
    end

    should "reject a calibrant who is also a participant" do
      err = assert_raises(Operations::Base::ParameterError) do
        define!(calibrant_person_ids: [ @report_1.id, @em_1.id ])
      end
      assert_match(/can't include session raters/, err.message)
    end

    should "reject a closed cycle" do
      closed = create(:assessment_cycle, :closed, tenant: @tenant)
      err = assert_raises(Operations::Base::ParameterError) { define!(cycle_id: closed.cycle_id) }
      assert_match(/cycle is closed/, err.message)
    end

    should "reject an unknown person id" do
      ghost = SecureRandom.uuid_v7
      err = assert_raises(Operations::Base::ParameterError) do
        define!(calibrant_person_ids: [ ghost ])
      end
      assert_match(/unknown people/, err.message)
    end

    should "reject a malformed uuid without hitting Postgres" do
      err = assert_raises(Operations::Base::ParameterError) do
        define!(participant_ids: [ "not-a-uuid" ])
      end
      assert_match(/must be a UUID/, err.message)
    end

    should "reject a blank name" do
      err = assert_raises(Operations::Base::ParameterError) { define!(name: "  ") }
      assert_match(/name can't be blank/, err.message)
    end

    should "allow a tenant admin to define with people outside their own subtree" do
      admin_person = create(:person, tenant: @tenant, name: "HR Admin")
      result = Operations::CalibrationSessions::Define.call(
        context: context_for(admin_person, role: :admin),
        params: {
          cycle_id: @cycle.cycle_id, name: "Org-wide calibration",
          participant_ids: [ @em_1.id ], calibrant_person_ids: [ @outsider.id ]
        }
      )
      assert_equal [ @outsider.id ], CalibrationSession.find(result[:session_id]).calibrants.pluck(:person_id)
    end
  end

  context "curation" do
    setup { @session_id = define![:session_id] }

    should "add and remove a calibrant" do
      extra = create(:person, tenant: @tenant, name: "Eve Extra", manager: @em_1)
      Operations::CalibrationSessions::AddCalibrant.call(
        context: @facilitator_context, params: { session_id: @session_id, person_id: extra.id }
      )
      assert_includes CalibrationSession.find(@session_id).calibrants.pluck(:person_id), extra.id

      Operations::CalibrationSessions::RemoveCalibrant.call(
        context: @facilitator_context, params: { session_id: @session_id, person_id: extra.id }
      )
      assert_not_includes CalibrationSession.find(@session_id).calibrants.pluck(:person_id), extra.id
    end

    should "reject adding a calibrant outside the facilitator's org" do
      err = assert_raises(Operations::Base::ParameterError) do
        Operations::CalibrationSessions::AddCalibrant.call(
          context: @facilitator_context, params: { session_id: @session_id, person_id: @outsider.id }
        )
      end
      assert_match(/not in the facilitator's org/, err.message)
    end

    should "promote a calibrant to participant" do
      Operations::CalibrationSessions::AddParticipant.call(
        context: @facilitator_context, params: { session_id: @session_id, person_id: @report_1.id }
      )

      session = CalibrationSession.find(@session_id)
      assert_includes session.participants.pluck(:person_id), @report_1.id
      assert_not_includes session.calibrants.pluck(:person_id), @report_1.id
    end

    should "remove a participant" do
      Operations::CalibrationSessions::RemoveParticipant.call(
        context: @facilitator_context, params: { session_id: @session_id, person_id: @em_2.id }
      )
      assert_not_includes CalibrationSession.find(@session_id).participants.pluck(:person_id), @em_2.id
    end

    should "deny curation to a non-facilitator manager of managers" do
      other_head = create(:person, tenant: @tenant, name: "Pat Peer")
      other_em = create(:person, tenant: @tenant, name: "Quinn", manager: other_head)
      create(:person, tenant: @tenant, name: "Rio", manager: other_em)

      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::AddCalibrant.call(
          context: context_for(other_head), params: { session_id: @session_id, person_id: @report_1.id }
        )
      end
    end
  end

  context "Start and Close" do
    setup { @session_id = define![:session_id] }

    should "start then close, stamping attribution" do
      Operations::CalibrationSessions::Start.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )
      session = CalibrationSession.find(@session_id)
      assert_equal "started", session.status
      assert_equal @dept_head.id, session.started_by_id

      Operations::CalibrationSessions::Close.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )
      session.reload
      assert_equal "closed", session.status
      assert_equal "facilitator", session.close_reason
      assert_equal @dept_head.id, session.closed_by_id
    end

    should "surface the frozen-after-start invariant on curation" do
      Operations::CalibrationSessions::Start.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )

      extra = create(:person, tenant: @tenant, manager: @em_1)
      err = assert_raises(RuntimeError) do
        Operations::CalibrationSessions::AddCalibrant.call(
          context: @facilitator_context, params: { session_id: @session_id, person_id: extra.id }
        )
      end
      assert_match(/already started/, err.message)
    end
  end

  context "Archive and Unarchive" do
    setup do
      @session_id = define![:session_id]
      Operations::CalibrationSessions::Close.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )
    end

    should "archive a closed session, hide it from List, and restore it" do
      result = Operations::CalibrationSessions::Archive.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )
      assert_equal({ session_id: @session_id, archived: true }, result)
      session = CalibrationSession.find(@session_id)
      assert session.archived?
      assert_equal @dept_head.id, session.archived_by_id
      got = Operations::CalibrationSessions::Get.call(context: @facilitator_context, params: { session_id: @session_id })
      assert_not_nil got[:archived_at], "Get says the session is archived"

      listed = Operations::CalibrationSessions::List.call(context: @facilitator_context, params: {})
      assert_empty listed[:sessions]
      listed = Operations::CalibrationSessions::List.call(
        context: @facilitator_context, params: { include_archived: true }
      )
      assert_equal [ @session_id ], listed[:sessions].map { |s| s[:session_id] }
      assert_not_nil listed[:sessions].first[:archived_at]

      Operations::CalibrationSessions::Unarchive.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )
      assert_not session.reload.archived?
      assert_equal "closed", session.status
    end

    should "treat a repeated archive as a no-op" do
      2.times do
        Operations::CalibrationSessions::Archive.call(
          context: @facilitator_context, params: { session_id: @session_id }
        )
      end
      stream = EventStreamNaming.calibration_session_stream(@session_id)
      archived = Rails.configuration.event_store.read.stream(stream)
        .of_type(AssessmentCycles::Events::CalibrationSessionArchived).count
      assert_equal 1, archived
    end

    should "deny archiving a session that isn't closed" do
      live_id = define!(name: "Still live")[:session_id]
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::Archive.call(
          context: @facilitator_context, params: { session_id: live_id }
        )
      end
    end

    should "deny a participant" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::Archive.call(
          context: context_for(@em_1), params: { session_id: @session_id }
        )
      end
    end
  end

  context "Rename" do
    setup { @session_id = define![:session_id] }

    should "rename with the stripped name and record the previous one" do
      result = Operations::CalibrationSessions::Rename.call(
        context: @facilitator_context, params: { session_id: @session_id, name: "  Engineering · H2  " }
      )
      assert_equal({ session_id: @session_id, name: "Engineering · H2" }, result)

      event = Rails.configuration.event_store.read
        .stream(EventStreamNaming.calibration_session_stream(@session_id))
        .of_type(AssessmentCycles::Events::CalibrationSessionRenamed).last
      assert_equal "Engineering calibration", event.data[:previous_name]
      assert_equal @dept_head.id, event.data[:renamed_by_id]
    end

    should "rename a closed session" do
      Operations::CalibrationSessions::Close.call(context: @facilitator_context, params: { session_id: @session_id })
      Operations::CalibrationSessions::Rename.call(
        context: @facilitator_context, params: { session_id: @session_id, name: "Done" }
      )
      assert_equal "Done", CalibrationSession.find(@session_id).name
    end

    should "reject a blank name at the parameter boundary" do
      assert_raises(Operations::Base::ParameterError) do
        Operations::CalibrationSessions::Rename.call(
          context: @facilitator_context, params: { session_id: @session_id, name: "" }
        )
      end
    end

    should "deny a participant" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::Rename.call(
          context: context_for(@em_1), params: { session_id: @session_id, name: "Mine now" }
        )
      end
    end
  end

  context "List and Get" do
    setup { @session_id = define![:session_id] }

    should "list only the caller's facilitated sessions" do
      create(:calibration_session, tenant: @tenant, name: "Someone else's")

      result = Operations::CalibrationSessions::List.call(context: @facilitator_context, params: {})
      assert_equal [ @session_id ], result[:sessions].map { |s| s[:session_id] }
      assert_equal 2, result[:sessions].first[:participant_count]
      assert_equal 2, result[:sessions].first[:calibrant_count]
    end

    should "list every session for a tenant admin, filterable by cycle" do
      create(:calibration_session, tenant: @tenant, name: "Other")
      admin_ctx = context_for(create(:person, tenant: @tenant), role: :admin)

      all = Operations::CalibrationSessions::List.call(context: admin_ctx, params: {})
      assert_equal 2, all[:sessions].size

      filtered = Operations::CalibrationSessions::List.call(
        context: admin_ctx, params: { cycle_id: @cycle.cycle_id }
      )
      assert_equal [ @session_id ], filtered[:sessions].map { |s| s[:session_id] }
    end

    should "return rosters with names on Get" do
      result = Operations::CalibrationSessions::Get.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )

      assert_equal "Engineering calibration", result[:name]
      assert_equal %w[Mia\ Manager Raj\ Rater], result[:participants].map { |p| p[:name] }
      assert_equal [ @report_1.id, @report_2.id ].sort, result[:calibrants].map { |c| c[:person_id] }.sort
    end

    should "deny Get to a participant (v1 facilitator-only)" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::Get.call(
          context: context_for(@em_1), params: { session_id: @session_id }
        )
      end
    end

    should "return the overview with rater names" do
      result = Operations::CalibrationSessions::Overview.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )

      assert_equal @session_id, result[:session_id]
      assert_equal [ "Mia Manager", "Raj Rater" ], result[:raters].map { |r| r[:name] }.sort
      assert result.key?(:capabilities)
    end

    should "carry readiness as cell coverage, per rater and for the population" do
      result = Operations::CalibrationSessions::Overview.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )

      rater = result[:raters].first
      %i[cell_total coverage_pct carried_pct evidence_coverage_pct ready_state evidence_pct].each do |key|
        assert rater.key?(key), "rater rows carry #{key}"
      end
      %i[cell_total coverage_pct carried_pct evidence_coverage_pct ready_state reference].each do |key|
        assert result[:readiness].key?(key), "readiness carries #{key}"
      end
    end

    should "carry the level cohorts with names and the coverage gate intact" do
      # This fixture has no scorable ladder, so everyone in a cohort is
      # GATED — exactly the payload shape an agent must read correctly:
      # pct nil + rated/total/unlock_target, never a fake low number.
      family = create(:framework_role_family, tenant: @tenant, framework_id: @cycle.framework_id)
      engineer = create(:framework_role, tenant: @tenant, role_family_id: family.role_family_id)
      create(:framework_level, tenant: @tenant, role_id: engineer.role_id, ordinal: 3)
      # This fixture never enrolls anyone — the cohort's whole input is the
      # cycle snapshot, so create it here.
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: @report_1.id, level_ordinal: 3, role_id: engineer.role_id)

      result = Operations::CalibrationSessions::Overview.call(
        context: @facilitator_context, params: { session_id: @session_id }
      )

      cohort = result[:cohorts].find { |c| c[:ordinal] == 3 }
      dot = cohort[:people].find { |d| d[:person_id] == @report_1.id }
      assert_equal "Ivy IC", dot[:name]
      assert_nil dot[:pct]
      assert_not dot[:unlocked]
      assert dot.key?(:unlock_target)
    end

    should "deny the overview to a participant" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::Overview.call(
          context: context_for(@em_1), params: { session_id: @session_id }
        )
      end
    end
  end
end
