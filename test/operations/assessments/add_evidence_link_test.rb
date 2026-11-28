# frozen_string_literal: true

require "test_helper"

class Operations::Assessments::AddEvidenceLinkTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Manager")
      @report = create(:person, tenant: @tenant, name: "Dana Direct", manager: @manager)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)

      framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@report.id, framework_id, role.role_id,
        FrameworkState::Level.find_by(role_id: role.role_id).level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @report.id, framework_id: framework_id)
      @evidence_id = SecureRandom.uuid_v7
      handler.record_evidence(@report.id, framework_id, @evidence_id, source: "peer",
        evidence_type: "peer_feedback", content: "Calm on the incident call.", author_id: @manager.id)
    end

    @context = AuthorizationContext.new(user: @manager_user, tenant_user: @tenant_user, person: @manager)
  end

  def call_op
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::AddEvidenceLink.call(context: @context, params: {
        assignment_id: @assignment.id, evidence_id: @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, valence: "demonstrated"
      })
    end
  end

  should "place feedback about someone still here" do
    assert_equal [ @cap.stable_id ], call_op[:links].map { |link| link[:capability_stable_id] }
  end

  should "refuse to place feedback about a forgotten person, as invalid input" do
    ActsAsTenant.with_tenant(@tenant) do
      @report.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
    end

    error = assert_raises(Operations::Base::ParameterError) { call_op }
    assert_equal "this person has been forgotten", error.message
    assert ActsAsTenant.with_tenant(@tenant) { EvidenceItem.unplaced.exists?(id: @evidence_id) }
  end
end
