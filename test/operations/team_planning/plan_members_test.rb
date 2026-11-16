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

  def grant(person_id, as: @editor) = call(Operations::TeamPlanning::GrantSeePay, as:, plan_id: @plan_id, person_id:)

  def withdraw(person_id, as: @editor) = call(Operations::TeamPlanning::WithdrawSeePay, as:, plan_id: @plan_id, person_id:)

  def holder(person_id, as: @editor) = members(as:).find { it[:person_id] == person_id }

  should "list a person's plans with their role, and nobody else's" do
    add(@colleague.person_id, "viewer")
    call(Operations::TeamPlanning::CreatePlan, as: @admin, name: "Admin's own")

    assert_equal [ { plan_id: @plan_id, name: "Next year", base_on: Date.current.iso8601, role: "viewer", archived_on: nil } ],
                 call(Operations::TeamPlanning::Plans, as: @colleague)[:plans]
    assert_equal [ "Admin's own" ], call(Operations::TeamPlanning::Plans, as: @admin)[:plans].pluck(:name)
  end

  should "list a person's plans by name, case aside, with a removed name last" do
    gone = call(Operations::TeamPlanning::CreatePlan, as: @editor, name: "Aardvark plan")[:plan_id]
    call(Operations::TeamPlanning::CreatePlan, as: @editor, name: "Zebra plan")
    call(Operations::TeamPlanning::CreatePlan, as: @editor, name: "apple plan")
    ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.forget(PlanKeyStore.plan_identifier(@tenant.id, gone)) }

    assert_equal [ "apple plan", "Next year", "Zebra plan", nil ],
                 call(Operations::TeamPlanning::Plans, as: @editor)[:plans].pluck(:name)
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

  context "the see-pay right" do
    setup { add(@colleague.person_id, "viewer") }

    should "show the creator holding it from the start, and who granted it" do
      creator = holder(@editor.person_id)
      assert creator[:see_pay]
      assert_equal({ by_id: @editor.person_id, by_name: @editor.person.name, recovery: false },
                   creator[:see_pay_granted].except(:at))
      assert_equal({ person_id: @colleague.person_id, name: @colleague.person.name, role: "viewer", see_pay: false },
                   holder(@colleague.person_id))
    end

    should "let a holder grant it and take it back" do
      assert_equal({ plan_id: @plan_id, person_id: @colleague.person_id, see_pay: true }, grant(@colleague.person_id))
      assert_equal @editor.person_id, holder(@colleague.person_id, as: @colleague)[:see_pay_granted][:by_id]

      assert_equal({ plan_id: @plan_id, person_id: @colleague.person_id, see_pay: false }, withdraw(@colleague.person_id))
      assert_nil holder(@colleague.person_id)[:see_pay_granted]
    end

    should "refuse a member who doesn't hold it as though the plan weren't there" do
      [ -> { grant(@colleague.person_id, as: @colleague) }, -> { withdraw(@editor.person_id, as: @colleague) } ].each do |command|
        assert_equal "No such plan", assert_raises(Operations::Base::ParameterError, &command).message
      end
    end

    should "refuse to leave the plan with nobody who can grant it" do
      error = assert_raises(Operations::Base::ParameterError) { withdraw(@editor.person_id) }
      assert_match "A plan needs someone who can see pay", error.message
    end

    context "once its only holder leaves" do
      setup do
        add(@colleague.person_id, "editor")
        @editor.person.update!(status: "inactive")
      end

      should "let a tenant admin restore it unread, to the editors left, as the admin's grant" do
        assert_equal({ plan_id: @plan_id, restored: true },
                     call(Operations::TeamPlanning::RestoreSeePay, as: @admin, plan_id: @plan_id))

        assert_equal({ by_id: @admin.person_id, by_name: @admin.person.name, recovery: true },
                     holder(@colleague.person_id, as: @colleague)[:see_pay_granted].except(:at))
        assert_raises(Operations::Base::ParameterError) { members(as: @admin) }
      end

      should "refuse anyone but a tenant admin, as an unknown plan" do
        error = assert_raises(Operations::Base::ParameterError) do
          call(Operations::TeamPlanning::RestoreSeePay, as: @colleague, plan_id: @plan_id)
        end
        assert_equal "No such plan", error.message
      end
    end

    should "refuse a tenant admin a plan that has a holder, as an unknown plan" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::RestoreSeePay, as: @admin, plan_id: @plan_id)
      end
      assert_equal "No such plan", error.message
    end
  end
end
