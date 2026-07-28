# frozen_string_literal: true

require "test_helper"

# Requesting a rating revisit records the session event AND (via the
# CalibrationRevisitSync handler, same transaction) mirrors it onto the
# person's PD stream so the rater's assessment feed carries the nudge.
class Operations::CalibrationSessions::RequestRatingRevisitTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em = create(:person, tenant: @tenant, name: "Mia Manager", manager: @dept_head)
    @report = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em)
    @outside_report = create(:person, tenant: @tenant, name: "Ref IC")

    @framework_id = SecureRandom.uuid_v7
    @cap_stable = SecureRandom.uuid_v7
    cap_id = SecureRandom.uuid_v7
    role_id = SecureRandom.uuid_v7
    level_id = SecureRandom.uuid_v7
    handler = Frameworks::CommandHandler.new
    handler.create_framework(@framework_id, "Eng")
    rfid = SecureRandom.uuid_v7
    handler.add_role_family(@framework_id, rfid, "Engineering")
    handler.add_role(@framework_id, role_id, rfid, "Software Engineer", "E", "ic")
    handler.add_level(@framework_id, level_id, role_id, 3, "Engineer III", "E3")
    cat_id = SecureRandom.uuid_v7
    handler.add_capability_category(@framework_id, cat_id, "Thinking")
    handler.add_capability(@framework_id, cap_id, @cap_stable, cat_id, "Strategic Thinking")
    handler.publish_version(@framework_id, "seed")

    # The PD mirror requires the person to be assigned to the framework.
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      [ @report, @outside_report ].each do |person|
        PersonDevelopment::CommandHandler.new.assign_to_framework(
          person.id, @framework_id, role_id, level_id
        )
      end
    end

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)

    @session_id = SecureRandom.uuid_v7
    calibration = AssessmentCycles::CalibrationCommandHandler.new
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      calibration.define_session(@session_id, @cycle.cycle_id, @framework_id, "Engineering calibration", 1,
                                 facilitator_id: @dept_head.id,
                                 participant_ids: [ @em.id ],
                                 calibrant_person_ids: [ @report.id, @outside_report.id ])
      calibration.start_session(@session_id, started_by_id: @dept_head.id)
    end

    @facilitator_context = context_for(@dept_head)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def context_for(person, role: :member)
    user = create(:user)
    tenant_user = create(:tenant_user, user: user, tenant: @tenant, role: role, person: person)
    AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person)
  end

  def revisit!(params = {})
    Operations::CalibrationSessions::RequestRatingRevisit.call(
      context: @facilitator_context,
      params: {
        session_id: @session_id,
        person_id: @report.id,
        capability_stable_id: @cap_stable,
        level_ordinal: 3,
        note: "The room compared this against two peers — worth a second look"
      }.merge(params)
    )
  end

  def pd_revisit_events(person)
    stream = EventStreamNaming.person_development_stream(person.id, @framework_id)
    Rails.configuration.event_store.read.stream(stream).to_a
      .select { |e| e.is_a?(PersonDevelopment::Events::RatingRevisitRequested) }
  end

  context "as the facilitator on a live session" do
    should "resolve the rater and record the session outcome" do
      result = revisit!

      assert_equal @em.id, result[:rater_id]
      revisits = CalibrationSessions::SessionOutcomes.new(session: CalibrationSession.find(@session_id))
        .revisit_requests
      assert_equal 1, revisits.size
      assert_equal @report.id, revisits.first[:person_id]
      assert_equal @em.id, revisits.first[:rater_id]
      assert_equal @dept_head.id, revisits.first[:requested_by_id]
    end

    should "mirror onto the person's PD stream with session provenance" do
      revisit!

      events = pd_revisit_events(@report)
      assert_equal 1, events.size
      data = events.first.data
      assert_equal @cap_stable, data[:capability_stable_id]
      assert_equal 3, data[:level_ordinal]
      assert_equal @session_id, data[:calibration_session_id]
      assert_equal "Engineering calibration", data[:session_name]
      assert_equal @em.id, data[:rater_id]
      assert_equal @dept_head.id, data[:requested_by_id]
      assert_not data.key?(:suggested_frequency), "value-free by design"
    end

    should "refuse a person whose rater is not in the session" do
      err = assert_raises(Operations::Base::ParameterError) { revisit!(person_id: @outside_report.id) }
      assert_match(/not a participant/, err.message)
      assert_empty pd_revisit_events(@outside_report)
    end

    should "refuse a blank note" do
      assert_raises(Operations::Base::ParameterError) { revisit!(note: "  ") }
    end

    should "refuse a duplicate ask for the same cell as invalid params" do
      revisit!
      err = assert_raises(Operations::Base::ParameterError) { revisit! }
      assert_match(/already requested/, err.message)
      assert_equal 1, pd_revisit_events(@report).size
    end
  end

  context "guards" do
    should "classify a PD-side refusal as invalid params, not an internal error" do
      # A person with an assignment READ-MODEL row but no PD stream
      # assignment (projection drift / manual row): the mirror's aggregate
      # raises CommandError inside the same transaction — the op must
      # surface it as ParameterError (→ flash on web, -32602 over MCP).
      ghost = create(:person, tenant: @tenant, name: "Ghost Row", manager: @em)
      create(:person_framework_assignment, tenant: @tenant,
             person_id: ghost.id, framework_id: @framework_id)

      ghost_session = SecureRandom.uuid_v7
      calibration = AssessmentCycles::CalibrationCommandHandler.new
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        calibration.define_session(ghost_session, @cycle.cycle_id, @framework_id, "Ghost session", 1,
                                   facilitator_id: @dept_head.id,
                                   participant_ids: [ @em.id ],
                                   calibrant_person_ids: [ ghost.id ])
        calibration.start_session(ghost_session, started_by_id: @dept_head.id)
      end

      err = assert_raises(Operations::Base::ParameterError) do
        Operations::CalibrationSessions::RequestRatingRevisit.call(
          context: @facilitator_context,
          params: { session_id: ghost_session, person_id: ghost.id,
                    capability_stable_id: @cap_stable, level_ordinal: 3, note: "n" }
        )
      end
      assert_match(/not yet assigned/i, err.message)
    end

    should "deny a participant EM" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::RequestRatingRevisit.call(
          context: context_for(@em),
          params: { session_id: @session_id, person_id: @report.id,
                    capability_stable_id: @cap_stable, level_ordinal: 3, note: "n" }
        )
      end
    end
  end
end
