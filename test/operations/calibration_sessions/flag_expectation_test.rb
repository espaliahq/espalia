# frozen_string_literal: true

require "test_helper"

# Flagging an expectation from a live session raises a framework
# clarification (framework stream) and records session provenance
# (session stream) carrying the resulting suggestion_id.
class Operations::CalibrationSessions::FlagExpectationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em = create(:person, tenant: @tenant, name: "Mia Manager", manager: @dept_head)
    @report = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em)

    # A real framework (stream + read models) the session references.
    @framework_id = SecureRandom.uuid_v7
    @cap_stable = SecureRandom.uuid_v7
    @cap_id = SecureRandom.uuid_v7
    @exp_id = SecureRandom.uuid_v7
    handler = Frameworks::CommandHandler.new
    handler.create_framework(@framework_id, "Eng")
    rfid = SecureRandom.uuid_v7
    role_id = SecureRandom.uuid_v7
    handler.add_role_family(@framework_id, rfid, "Engineering")
    handler.add_role(@framework_id, role_id, rfid, "Software Engineer", "E", "ic")
    handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 4, "Engineer IV", "E4")
    handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 6, "Engineer VI", "E6")
    cat_id = SecureRandom.uuid_v7
    handler.add_capability_category(@framework_id, cat_id, "Thinking")
    handler.add_capability(@framework_id, @cap_id, @cap_stable, cat_id, "Strategic Thinking")
    handler.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7, @cap_id, 4, "Shapes direction")
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
    Operations::CalibrationSessions::FlagExpectation.call(
      context: @facilitator_context,
      params: {
        session_id: @session_id,
        capability_stable_id: @cap_stable,
        level_ordinal: 4,
        reason: "Raters diverged two bands beyond tendency"
      }.merge(params)
    )
  end

  context "as the facilitator on a live session" do
    should "raise a framework clarification anchored on the cell's expectation" do
      result = flag!

      assert_equal "behavioural_expectation", result[:target_entity_type]
      clarification = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
      assert_equal "clarification", clarification.kind
      assert_equal "pending", clarification.status
      assert_equal @exp_id, clarification.target_entity_id
      assert_equal @dept_head.id, clarification.author_id
      assert_includes clarification.rationale, "Flagged during Engineering calibration"
      assert_includes clarification.rationale, "Raters diverged two bands beyond tendency"
    end

    should "record session provenance carrying the suggestion_id" do
      result = flag!

      flags = CalibrationSessions::SessionOutcomes.new(session: CalibrationSession.find(@session_id)).flags
      assert_equal 1, flags.size
      assert_equal result[:suggestion_id], flags.first[:suggestion_id]
      assert_equal @cap_stable, flags.first[:capability_stable_id]
      assert_equal 4, flags.first[:level_ordinal]
      assert_equal @dept_head.id, flags.first[:flagged_by_id]
    end

    should "anchor on the capability with the level when the cell has no expectation" do
      result = flag!(level_ordinal: 6, reason: nil)

      assert_equal "capability", result[:target_entity_type]
      clarification = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
      assert_equal @cap_id, clarification.target_entity_id
      assert_equal 6, clarification.proposed_attributes["level_ordinal"]
      assert_includes clarification.rationale, "raters read this expectation inconsistently"
    end

    should "refuse a second flag on the same cell in the same session" do
      flag!
      err = assert_raises(Operations::Base::ParameterError) { flag! }
      assert_match(/already flagged/, err.message)
      assert_equal 1, FrameworkState::SuggestedEdit.clarifications.count,
        "the framework must not accumulate a second clarification from the pre-check failure"
    end

    should "surface the open clarification in the drill-in stats" do
      flag!
      stats = CalibrationSessions::DrillInStats.new(
        session: CalibrationSession.find(@session_id), capability_stable_id: @cap_stable
      ).call
      assert_equal 1, stats[:clarifications][4]
    end
  end

  context "guards" do
    should "refuse a tenant admin with no linked person (clean invalid-params, not a projection 500)" do
      admin_user = create(:user)
      admin_tu = create(:tenant_user, tenant: @tenant, user: admin_user, role: :admin)
      ctx = AuthorizationContext.new(user: admin_user, tenant_user: admin_tu, person: nil)

      err = assert_raises(Operations::Base::ParameterError) do
        Operations::CalibrationSessions::FlagExpectation.call(
          context: ctx,
          params: { session_id: @session_id, capability_stable_id: @cap_stable,
                    level_ordinal: 4, reason: "?" }
        )
      end
      assert_match(/linked person/, err.message)
      assert_equal 0, FrameworkState::SuggestedEdit.clarifications.count
    end

    should "refuse a level that doesn't exist in the framework" do
      err = assert_raises(Operations::Base::ParameterError) { flag!(level_ordinal: 99, reason: nil) }
      assert_match(/does not exist/, err.message)
      assert_equal 0, FrameworkState::SuggestedEdit.clarifications.count
    end

    should "refuse flagging a draft session" do
      draft_id = SecureRandom.uuid_v7
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        AssessmentCycles::CalibrationCommandHandler.new.define_session(
          draft_id, @cycle.cycle_id, @framework_id, "Draft session", 1,
          facilitator_id: @dept_head.id, participant_ids: [ @em.id ], calibrant_person_ids: [ @report.id ]
        )
      end

      err = assert_raises(Operations::Base::ParameterError) { flag!(session_id: draft_id) }
      assert_match(/live session/, err.message)
    end

    should "deny a non-facilitator (participant EMs included)" do
      assert_raises(Pundit::NotAuthorizedError) do
        Operations::CalibrationSessions::FlagExpectation.call(
          context: context_for(@em),
          params: { session_id: @session_id, capability_stable_id: @cap_stable, level_ordinal: 4 }
        )
      end
    end

    should "404 an unknown capability stable id" do
      assert_raises(ActiveRecord::RecordNotFound) { flag!(capability_stable_id: SecureRandom.uuid_v7) }
    end
  end
end
