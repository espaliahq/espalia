# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::PlanMembersTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(:member, team_planner: true)
      @colleague = account(:member)
      @admin = account(:admin)
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, as: @editor, name: "Next year")[:plan_id]
  end

  def account(role, **grants) = create(:tenant_user, tenant: @tenant, role:, person: create(:person, tenant: @tenant), **grants)

  def call(operation, as:, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def members(as: @editor) = call(Operations::TeamPlanning::PlanMembers, as:, plan_id: @plan_id)[:members]

  def add(person_id, role, as: @editor) = call(Operations::TeamPlanning::AddPlanMember, as:, plan_id: @plan_id, person_id:, role:)

  should "list a person's plans with their role, and nobody else's" do
    add(@colleague.person_id, "viewer")
    call(Operations::TeamPlanning::CreatePlan, as: @admin, name: "Admin's own")

    assert_equal [ { plan_id: @plan_id, name: "Next year", base_on: Date.current.iso8601, role: "viewer" } ],
                 call(Operations::TeamPlanning::Plans, as: @colleague)[:plans]
    assert_equal [ "Admin's own" ], call(Operations::TeamPlanning::Plans, as: @admin)[:plans].pluck(:name)
  end

  should "let an editor add a member and change their role, and the member see who is in it" do
    assert_equal({ plan_id: @plan_id, person_id: @colleague.person_id, role: "viewer" }, add(@colleague.person_id, "viewer"))
    add(@colleague.person_id, "editor")

    assert_equal [ { person_id: @colleague.person_id, role: "editor" }, { person_id: @editor.person_id, role: "editor" } ].sort_by { it[:person_id] },
                 members(as: @colleague).map { it.slice(:person_id, :role) }
  end

  should "let a viewer leave, and not take anyone else off" do
    add(@colleague.person_id, "viewer")
    assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::RemovePlanMember, as: @colleague, plan_id: @plan_id, person_id: @editor.person_id)
    end

    call(Operations::TeamPlanning::RemovePlanMember, as: @colleague, plan_id: @plan_id, person_id: @colleague.person_id)
    assert_empty call(Operations::TeamPlanning::Plans, as: @colleague)[:plans]
  end

  should "refuse to leave a plan without an editor, or to make one of a role it doesn't know" do
    error = assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::RemovePlanMember, as: @editor, plan_id: @plan_id, person_id: @editor.person_id)
    end
    assert_match "A plan needs an editor", error.message
    assert_raises(Operations::Base::ParameterError) { add(@colleague.person_id, "owner") }
  end

  should "refuse a write from a viewer as though the plan weren't there" do
    add(@colleague.person_id, "viewer")
    error = assert_raises(Operations::Base::ParameterError) { add(@admin.person_id, "editor", as: @colleague) }
    assert_equal "No such plan", error.message
  end

  context "a frozen plan" do
    setup do
      add(@colleague.person_id, "viewer")
      ActsAsTenant.with_tenant(@tenant) do
        @editor.person.update!(status: "inactive")
        OrgLeaver.create!(tenant: @tenant, person_id: @editor.person_id, left_on: Date.new(2026, 11, 2))
      end
    end

    should "stay readable by its viewers, and changeable by nobody" do
      assert_equal [ "Next year" ], call(Operations::TeamPlanning::Plans, as: @colleague)[:plans].pluck(:name)
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::RenamePlan, as: @colleague, plan_id: @plan_id, name: "Mine now")
      end
    end

    should "show a tenant admin that it exists, when it froze and how many viewers it has, and nothing more" do
      result = call(Operations::TeamPlanning::FrozenPlans, as: @admin)

      assert_equal 1, result[:plans].size
      entry = result[:plans].sole
      assert_equal %i[frozen_on plan_id viewer_count], entry.keys.sort
      assert_equal @plan_id, entry[:plan_id]
      assert_equal 1, entry[:viewer_count]
      assert_equal "2026-11-02", entry[:frozen_on]
      assert_not_includes result.to_json, "Next year"
      assert_not_includes result.to_json, @colleague.person_id
    end

    should "count only viewers who can still read it, and give no day when nobody recorded one" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgLeaver.delete_all
        @colleague.person.update!(status: "inactive")
      end

      entry = call(Operations::TeamPlanning::FrozenPlans, as: @admin)[:plans].sole
      assert_equal 0, entry[:viewer_count]
      assert_nil entry[:frozen_on]
    end

    should "let a tenant admin delete it unread, keeping who and why" do
      result = call(Operations::TeamPlanning::DeleteFrozenPlan, as: @admin, plan_id: @plan_id, reason: "Its only editor left")

      assert_equal({ plan_id: @plan_id, deleted: true }, result)
      event = Rails.configuration.event_store.read.stream(EventStreamNaming.plan_stream(@plan_id, tenant: @tenant)).to_a.last
      assert_equal({ plan_id: @plan_id, deleted_by_id: @admin.person_id, reason: "Its only editor left" }, event.data)
      assert_empty call(Operations::TeamPlanning::FrozenPlans, as: @admin)[:plans]
    end

    should "still not open for the admin" do
      [ -> { members(as: @admin) }, -> { call(Operations::TeamPlanning::RenamePlan, as: @admin, plan_id: @plan_id, name: "x") } ].each do |read|
        assert_equal "No such plan", assert_raises(Operations::Base::ParameterError, &read).message
      end
    end
  end

  context "a plan with an editor" do
    should "be out of the admin's frozen list and delete path" do
      assert_empty call(Operations::TeamPlanning::FrozenPlans, as: @admin)[:plans]
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::DeleteFrozenPlan, as: @admin, plan_id: @plan_id, reason: "Tidying up")
      end
      assert_equal "No such plan", error.message
    end

    should "keep the frozen list from anyone but a tenant admin" do
      assert_raises(Pundit::NotAuthorizedError) { call(Operations::TeamPlanning::FrozenPlans, as: @editor) }
    end
  end
end
