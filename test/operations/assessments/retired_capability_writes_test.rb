# frozen_string_literal: true

require "test_helper"

# #615: the tools that create something on a capability take only an active
# capability of the published framework, whatever version the person stands on.
class Operations::Assessments::RetiredCapabilityWritesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @report_user = create(:user)
    @aligned_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, name: "Mgr")
      @report  = create(:person, tenant: @tenant, manager_id: @manager.id, email: @report_user.email, name: "Rep")
      @aligned = create(:person, tenant: @tenant, manager_id: @manager.id, email: @aligned_user.email, name: "Done")
      @report_tu  = create(:tenant_user, tenant: @tenant, user: @report_user, person: @report, role: :member)
      @aligned_tu = create(:tenant_user, tenant: @tenant, user: @aligned_user, person: @aligned, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      @retired = create(:framework_capability, category_id: cat.category_id, name: "Old Thinking", status: "archived")
      [ @cap, @retired ].each do |capability|
        create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation, capability_id: capability.capability_id, level_ordinal: 2, description: "X")
      end

      pd = PersonDevelopment::CommandHandler.new
      cycles = AssessmentCycles::CommandHandler.new
      [ @report, @aligned ].each { |person| pd.assign_to_framework(person.id, @framework_id, role.role_id, level.level_id) }
      @cycle_id = SecureRandom.uuid_v7
      cycles.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @manager.id)
      [ @report, @aligned ].each { |person| cycles.enroll(@cycle_id, person.id, enrolled_by: @manager.id) }
      AssessmentCycleProgress.find_or_initialize_by(cycle_id: @cycle_id, person_id: @aligned.id)
        .update!(status: "aligned", aligned_at: Time.current)

      create(:framework_migration_mapping, framework_id: @framework_id, from_stable_id: @retired.stable_id,
        to_stable_id: @cap.stable_id, mapping_type: "evolved", requires_reassessment: false,
        published_version: 2, reason: "merged")
      Frameworks::SyncHandlers::FrameworkVersionMigrationSync.new.call(
        Frameworks::Events::FrameworkVersionPublished.new(
          data: { framework_id: @framework_id, version: 2, published_by: "tester" },
          metadata: { tenant_id: @tenant.id }
        )
      )
    end

    @contexts = {
      @report.id => AuthorizationContext.new(user: @report_user, tenant_user: @report_tu, person: @report),
      @aligned.id => AuthorizationContext.new(user: @aligned_user, tenant_user: @aligned_tu, person: @aligned)
    }
  end

  def assignment_for(person)
    ActsAsTenant.with_tenant(@tenant) { PersonFrameworkAssignment.for_person(person.id).first }
  end

  def call(operation, person, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: @contexts.fetch(person.id), params: { assignment_id: assignment_for(person).id, **params })
    end
  end

  def record_evidence(person, capability_stable_id)
    call(Operations::Assessments::RecordEvidence, person, capability_stable_id: capability_stable_id, level_ordinal: 2,
      evidence_type: "project_outcome", content: "Led the refactor.", valence: "demonstrated")
  end

  def add_link(person, capability_stable_id)
    evidence_id = call(Operations::Assessments::RecordEvidence, person, evidence_type: "project_outcome",
      content: "Unplaced so far.")[:evidence_id]
    call(Operations::Assessments::AddEvidenceLink, person, evidence_id: evidence_id,
      capability_stable_id: capability_stable_id, level_ordinal: 2, valence: "demonstrated")
  end

  def post_comment(person, capability_stable_id)
    call(Operations::Assessments::PostComment, person, capability_stable_id: capability_stable_id, level_ordinal: 2, body: "Thoughts")
  end

  def request_evidence(person, capability_stable_id)
    call(Operations::Assessments::RequestEvidence, person, requestee_person_id: @manager.id,
      capability_stable_id: capability_stable_id, level_ordinal: 2, message: "Help please")
  end

  def migrated?(person)
    ActsAsTenant.with_tenant(@tenant) do
      stream = EventStreamNaming.person_development_stream(person.id, @framework_id)
      Rails.configuration.event_store.read.stream(stream).of_type([ PersonDevelopment::Events::FrameworkVersionMigrated ]).to_a.any?
    end
  end

  WRITES = %i[record_evidence add_link post_comment request_evidence].freeze

  should "migrate the in-progress person and skip the completed-alignment one" do
    assert migrated?(@report)
    assert_not migrated?(@aligned)
  end

  WRITES.each do |write|
    should "refuse #{write} on a retired capability, for a migrated person and one the publish skipped" do
      [ @report, @aligned ].each do |person|
        err = assert_raises(Operations::Base::ParameterError) { send(write, person, @retired.stable_id) }
        assert_equal "capability_stable_id #{@retired.stable_id} is not an active capability in the published framework", err.message
      end
    end

    should "refuse #{write} on a made-up capability id" do
      made_up = SecureRandom.uuid_v7
      err = assert_raises(Operations::Base::ParameterError) { send(write, @report, made_up) }
      assert_equal "capability_stable_id #{made_up} is not an active capability in the published framework", err.message
    end

    should "accept #{write} on an active capability" do
      assert_nothing_raised { send(write, @report, @cap.stable_id) }
    end
  end
end
