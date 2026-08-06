# frozen_string_literal: true

require "test_helper"

# §f: a request fired from a live session rides the existing
# PersonDevelopment machinery (EvidenceRequest read model, requestee
# notification) and records provenance on the session stream so the
# follow-through page can track it.
class Operations::CalibrationSessions::RequestEvidenceTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept")
    @em = create(:person, tenant: @tenant, name: "Mia Manager", manager: @dept_head)
    @report = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em)
    @peer = create(:person, tenant: @tenant, name: "Pat Peer", manager: @em)

    # A real framework (stream + read models) the session references.
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
    handler.add_level(@framework_id, level_id, role_id, 4, "Engineer IV", "E4")
    cat_id = SecureRandom.uuid_v7
    handler.add_capability_category(@framework_id, cat_id, "Thinking")
    handler.add_capability(@framework_id, cap_id, @cap_stable, cat_id, "Strategic Thinking")
    handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7,
                                        SecureRandom.uuid_v7, cap_id, 4, "Shapes direction")
    handler.publish_version(@framework_id, "seed")

    # Real PD assignment — the request lands on this stream, whose
    # aggregate requires one; its projection also writes the assignment
    # row the entitlement check anchors on.
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      PersonDevelopment::CommandHandler.new.assign_to_framework(
        @report.id, @framework_id, role_id, level_id
      )
    end

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)

    @session_id = SecureRandom.uuid_v7
    calibration = AssessmentCycles::CalibrationCommandHandler.new
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      calibration.define_session(@session_id, @cycle.cycle_id, @framework_id,
                                 "Engineering calibration", 1,
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

  def request!(params = {}, context: @facilitator_context)
    Operations::CalibrationSessions::RequestEvidence.call(
      context: context,
      params: {
        session_id: @session_id,
        person_id: @report.id,
        requestee_person_id: @peer.id,
        capability_stable_id: @cap_stable,
        level_ordinal: 4,
        message: "The room couldn't answer what good looks like here."
      }.merge(params)
    )
  end

  context "as the facilitator on a live session" do
    should "create the request on the existing machinery AND record session provenance" do
      result = request!

      request = EvidenceRequest.find(result[:request_id])
      assert_equal "pending", request.status
      assert_equal @peer.id, request.requestee_person_id
      assert_equal @report.id, request.person_id
      assert_equal "The room couldn't answer what good looks like here.", request.message

      session = CalibrationSession.find(@session_id)
      recorded = CalibrationSessions::SessionOutcomes.new(session: session).evidence_requests
      assert_equal [ result[:request_id] ], recorded.map { |r| r[:request_id] }
      assert_equal @peer.id, recorded.first[:requestee_id]
      assert_equal @dept_head.id, recorded.first[:requested_by_id]
      assert_equal "The room couldn't answer what good looks like here.",
                   recorded.first[:message]
    end

    should "refuse a person outside the population" do
      error = assert_raises(Operations::Base::ParameterError) do
        request!({ person_id: @peer.id })
      end
      assert_match(/not in this session's population/, error.message)
    end

    should "refuse asking yourself" do
      error = assert_raises(Operations::Base::ParameterError) do
        request!({ requestee_person_id: @dept_head.id })
      end
      assert_match(/from yourself/, error.message)
    end

    should "refuse a duplicate pending ask on the same cell (the aggregate's rule)" do
      request!
      error = assert_raises(Operations::Base::ParameterError) { request! }
      # Whatever the PD aggregate's wording, it must classify as invalid
      # params, never bubble as a 500 / -32603.
      assert error.message.present?
      assert_equal 1, EvidenceRequest.where(person_id: @report.id).count
    end

    should "refuse a foreign capability" do
      error = assert_raises(Operations::Base::ParameterError) do
        request!({ capability_stable_id: SecureRandom.uuid_v7 })
      end
      assert_match(/does not belong to the session's framework/, error.message)
    end
  end

  context "lifecycle and authorization" do
    should "refuse a draft session" do
      CalibrationSession.find(@session_id).update!(status: "draft")

      error = assert_raises(Operations::Base::ParameterError) { request! }
      assert_match(/fired from a live session/, error.message)
      assert_equal 0, EvidenceRequest.count, "the request must not outlive the refusal"
    end

    should "deny a non-facilitator" do
      assert_raises(Pundit::NotAuthorizedError) do
        request!(context: context_for(@em))
      end
    end

    should "deny a facilitator without assessment entitlement for the person" do
      # The delegation exemption can put someone outside the facilitator's
      # subtree into the population — the session must not become a way to
      # fire requests about them. An unrelated dept head facilitating (via
      # admin-curated population) has the session bar but not the person's.
      outside_head = create(:person, tenant: @tenant, name: "Other Head")
      CalibrationSession.find(@session_id).update!(facilitator_id: outside_head.id)

      error = assert_raises(Pundit::NotAuthorizedError) do
        request!(context: context_for(outside_head))
      end
      assert error
      assert_equal 0, EvidenceRequest.count,
                   "the entitlement bar must hold BEFORE the request is created"
    end
  end
end
