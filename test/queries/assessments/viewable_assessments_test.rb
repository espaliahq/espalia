# frozen_string_literal: true

require "test_helper"

class Assessments::ViewableAssessmentsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @framework_id = SecureRandom.uuid_v7
    @grand_manager = create(:person, tenant: @tenant, name: "Grand Manager")
    @manager = create(:person, tenant: @tenant, name: "Manager", manager: @grand_manager)
    @report = create(:person, tenant: @tenant, name: "Report", manager: @manager)
    @peer = create(:person, tenant: @tenant, name: "Peer", manager: @manager)
    @outsider = create(:person, tenant: @tenant, name: "Outsider")

    [ @grand_manager, @manager, @report, @peer, @outsider ].each do |person|
      create(:person_framework_assignment, tenant: @tenant,
             person_id: person.id, framework_id: @framework_id)
    end
    @all_ids = [ @grand_manager, @manager, @report, @peer, @outsider ].map(&:id)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "as a tenant admin" do
    should "return every participant with an assignment" do
      result = call_for(context_for(@outsider, admin: true))
      assert_equal @all_ids.sort, result.keys.sort
    end

    should "omit people without an assignment on the framework" do
      unassigned = create(:person, tenant: @tenant, name: "Unassigned")
      result = Assessments::ViewableAssessments.new(
        viewer: context_for(@outsider, admin: true),
        framework_id: @framework_id,
        person_ids: @all_ids + [ unassigned.id ]
      ).call
      assert_not_includes result.keys, unassigned.id
    end
  end

  context "as a manager" do
    should "return self plus the whole subtree" do
      result = call_for(context_for(@grand_manager))
      assert_equal [ @grand_manager, @manager, @report, @peer ].map(&:id).sort, result.keys.sort
    end
  end

  context "as an individual contributor" do
    should "return only their own assessment" do
      result = call_for(context_for(@report))
      assert_equal [ @report.id ], result.keys
    end
  end

  context "as an active rating delegate" do
    should "include the delegated report" do
      create(:manager_assessment_delegation, tenant: @tenant,
             person_id: @report.id, framework_id: @framework_id,
             delegate_person_id: @outsider.id, granted_by_id: @manager.id)
      result = call_for(context_for(@outsider))
      assert_equal [ @outsider.id, @report.id ].sort, result.keys.sort
    end

    should "exclude a revoked delegation" do
      create(:manager_assessment_delegation, tenant: @tenant,
             person_id: @report.id, framework_id: @framework_id,
             delegate_person_id: @outsider.id, granted_by_id: @manager.id,
             status: "revoked")
      result = call_for(context_for(@outsider))
      assert_equal [ @outsider.id ], result.keys
    end
  end

  context "as a recorded reporting manager no longer in the live chain" do
    should "include the recorded report" do
      create(:recorded_reporting_manager, tenant: @tenant,
             person_id: @report.id, framework_id: @framework_id,
             manager_id: @outsider.id)
      result = call_for(context_for(@outsider))
      assert_includes result.keys, @report.id
    end
  end

  context "with no person linked" do
    should "return nothing for a non-admin" do
      user = create(:user)
      tenant_user = create(:tenant_user, tenant: @tenant, user: user)
      ctx = AuthorizationContext.new(user: user, tenant_user: tenant_user, person: nil)
      assert_empty call_for(ctx)
    end
  end

  # The load-bearing guarantee: for every (viewer, participant) pair the bulk
  # query agrees with AssessmentPolicy#show? on the participant's assignment.
  # If the policy gains or loses a clause, this fails until the query follows.
  context "parity with AssessmentPolicy#show?" do
    should "match the per-record policy for every viewer role" do
      create(:manager_assessment_delegation, tenant: @tenant,
             person_id: @report.id, framework_id: @framework_id,
             delegate_person_id: @outsider.id, granted_by_id: @manager.id)
      create(:recorded_reporting_manager, tenant: @tenant,
             person_id: @peer.id, framework_id: @framework_id,
             manager_id: @outsider.id)

      assignments = PersonFrameworkAssignment
        .where(framework_id: @framework_id).index_by(&:person_id)

      viewers = {
        "admin" => context_for(@outsider, admin: true),
        "grand manager" => context_for(@grand_manager),
        "manager" => context_for(@manager),
        "report" => context_for(@report),
        "outsider (delegate + recorded mgr)" => context_for(@outsider)
      }

      viewers.each do |label, ctx|
        bulk = Assessments::ViewableAssessments.new(
          viewer: ctx, framework_id: @framework_id, person_ids: @all_ids
        ).call
        @all_ids.each do |person_id|
          expected = AssessmentPolicy.new(ctx, assignments.fetch(person_id)).show?
          assert_equal expected, bulk.key?(person_id),
            "#{label} viewing #{Person.find(person_id).name}: bulk=#{bulk.key?(person_id)} policy=#{expected}"
        end
      end
    end
  end

  private

  def call_for(ctx)
    Assessments::ViewableAssessments.new(
      viewer: ctx, framework_id: @framework_id, person_ids: @all_ids
    ).call
  end

  def context_for(person, admin: false)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user: user, person: person,
                         role: admin ? :admin : :member)
    AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person)
  end
end
