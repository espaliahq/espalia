# frozen_string_literal: true

require "test_helper"

class Operations::CalibrationSessions::RecordNoteTest < ActiveSupport::TestCase
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

  def note!(params = {})
    Operations::CalibrationSessions::RecordNote.call(
      context: @facilitator_context,
      params: { session_id: @session_id, body: "We agreed to revisit next cycle" }.merge(params)
    )
  end

  should "record a note with no capability, and one on an active capability" do
    assert_equal @session_id, note![:session_id]
    assert_equal @session_id, note!(capability_stable_id: @cap_stable)[:session_id]
  end

  # #615
  should "refuse a note on a retired capability and on a made-up id alike" do
    category_id = FrameworkState::Capability.find_by!(stable_id: @cap_stable).category_id
    retired = create(:framework_capability, category_id: category_id, name: "Old Thinking", status: "archived")

    [ retired.stable_id, SecureRandom.uuid_v7 ].each do |id|
      err = assert_raises(Operations::Base::ParameterError) { note!(capability_stable_id: id) }
      assert_equal "capability_stable_id #{id} is not an active capability in the published framework", err.message
    end
  end
end
