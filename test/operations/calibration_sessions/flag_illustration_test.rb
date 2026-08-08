# frozen_string_literal: true

require "test_helper"

# Flagging ONE example from a live session raises an illustration-anchored
# framework clarification and records session provenance — independent of
# (and coexisting with) the cell's expectation flag.
class Operations::CalibrationSessions::FlagIllustrationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em = create(:person, tenant: @tenant, name: "Mia Manager", manager: @dept_head)
    @report = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em)

    @framework_id = SecureRandom.uuid_v7
    @cap_stable = SecureRandom.uuid_v7
    @cap_id = SecureRandom.uuid_v7
    @exp_id = SecureRandom.uuid_v7
    @illustration_id = SecureRandom.uuid_v7
    handler = Frameworks::CommandHandler.new
    handler.create_framework(@framework_id, "Eng")
    rfid = SecureRandom.uuid_v7
    role_id = SecureRandom.uuid_v7
    handler.add_role_family(@framework_id, rfid, "Engineering")
    handler.add_role(@framework_id, role_id, rfid, "Software Engineer", "E", "ic")
    handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 4, "Engineer IV", "E4")
    cat_id = SecureRandom.uuid_v7
    handler.add_capability_category(@framework_id, cat_id, "Thinking")
    handler.add_capability(@framework_id, @cap_id, @cap_stable, cat_id, "Strategic Thinking")
    handler.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7, @cap_id, 4, "Shapes direction")
    handler.add_role_illustration(@framework_id, @illustration_id, SecureRandom.uuid_v7,
                                  @exp_id, role_id, 1, "Chooses the pragmatic architecture")
    handler.publish_version(@framework_id, "seed")

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)

    @session_id = SecureRandom.uuid_v7
    calibration = AssessmentCycles::CalibrationCommandHandler.new
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      calibration.define_session(@session_id, @cycle.cycle_id, @framework_id, "Engineering calibration", 1,
                                 facilitator_id: @dept_head.id,
                                 participant_ids: [ @em.id ],
                                 calibrant_person_ids: [ @report.id ])
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

  def flag!(params = {})
    Operations::CalibrationSessions::FlagIllustration.call(
      context: @facilitator_context,
      params: {
        session_id: @session_id,
        illustration_id: @illustration_id,
        reason: "This example describes an L6 behaviour"
      }.merge(params)
    )
  end

  context "as the facilitator on a live session" do
    should "raise a clarification anchored on the illustration, with session provenance" do
      result = flag!

      assert_equal @illustration_id, result[:illustration_id]
      assert_equal @cap_stable, result[:capability_stable_id]
      assert_equal 4, result[:level_ordinal]

      clarification = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
      assert_equal "clarification", clarification.kind
      assert_equal "role_illustration", clarification.target_entity_type
      assert_equal @illustration_id, clarification.target_entity_id
      assert_includes clarification.rationale, "example under Strategic Thinking · L4"
      assert_includes clarification.rationale, "This example describes an L6 behaviour"

      flags = CalibrationSessions::SessionOutcomes.new(session: CalibrationSession.find(@session_id)).flags
      assert_equal [ @illustration_id ], flags.map { |f| f[:illustration_id] }
      assert_equal result[:suggestion_id], flags.first[:suggestion_id]
    end

    should "coexist with the cell's expectation flag, but never double-flag one example" do
      Operations::CalibrationSessions::FlagExpectation.call(
        context: @facilitator_context,
        params: { session_id: @session_id, capability_stable_id: @cap_stable, level_ordinal: 4 }
      )
      flag!

      error = assert_raises(Operations::Base::ParameterError) { flag! }
      assert_includes error.message, "already flagged"
    end

    should "reject an illustration from another framework" do
      foreign_fw = SecureRandom.uuid_v7
      foreign_ill = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(foreign_fw, "Other")
      rfid = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      handler.add_role_family(foreign_fw, rfid, "Ops")
      handler.add_role(foreign_fw, role_id, rfid, "Analyst", "A", "ic")
      handler.add_level(foreign_fw, SecureRandom.uuid_v7, role_id, 2, "Analyst II", "A2")
      cat = SecureRandom.uuid_v7
      handler.add_capability_category(foreign_fw, cat, "Ops")
      cap = SecureRandom.uuid_v7
      exp = SecureRandom.uuid_v7
      handler.add_capability(foreign_fw, cap, SecureRandom.uuid_v7, cat, "Reporting")
      handler.set_behavioural_expectation(foreign_fw, exp, SecureRandom.uuid_v7, cap, 2, "Reports")
      handler.add_role_illustration(foreign_fw, foreign_ill, SecureRandom.uuid_v7,
                                    exp, role_id, 1, "Builds dashboards")
      handler.publish_version(foreign_fw, "seed")

      assert_raises(ActiveRecord::RecordNotFound) { flag!(illustration_id: foreign_ill) }
    end
  end

  context "as a non-facilitator" do
    should "be denied" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::FlagIllustration.call(
          context: context_for(@em),
          params: { session_id: @session_id, illustration_id: @illustration_id }
        )
      end
    end
  end
end
