# frozen_string_literal: true

require "test_helper"

class Plans::SeePayControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    end
  end

  context "a member who holds the right" do
    setup { sign_in @editor.user }

    should "give it to another member, and show who gave it and when" do
      patch plan_see_pay_path(@plan_id, @viewer.person.id)

      assert_redirected_to plan_path(@plan_id)
      assert_equal "Vic Viewer can now see pay.", flash[:notice]
      assert sees_pay?(@viewer)

      get plan_path(@plan_id)
      assert_select "#plan-member-#{@viewer.person.id}", text: /Sees pay\s*Given by Erin Editor on 1 November 2026/
      assert_select "#plan-member-#{@viewer.person.id} button", text: "Withdraw pay access"
      assert_select "#plan-member-#{@editor.person.id}", text: /Sees pay\s*Since 1 November 2026/
    end

    should "withdraw it from another member" do
      ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::GrantSeePay, @editor, plan_id: @plan_id, person_id: @viewer.person.id) }
      delete plan_see_pay_path(@plan_id, @viewer.person.id)

      assert_equal "Vic Viewer can no longer see pay.", flash[:notice]
      assert_not sees_pay?(@viewer)
    end

    should "be offered no withdraw while the last holder, and be refused one with the reason" do
      get plan_path(@plan_id)
      assert_select "#plan-member-#{@editor.person.id} button", count: 0
      assert_select "#plan-member-#{@viewer.person.id} button", text: "Give pay access"

      delete plan_see_pay_path(@plan_id, @editor.person.id)
      assert_match(/\ACouldn't withdraw the right: A plan needs someone who can see pay/, flash[:alert])
      assert sees_pay?(@editor)
    end
  end

  context "a member without the right" do
    setup { sign_in @viewer.user }

    should "be refused a grant and offered no controls" do
      patch plan_see_pay_path(@plan_id, @viewer.person.id)
      assert_redirected_to root_path
      assert_not sees_pay?(@viewer)

      get plan_path(@plan_id)
      assert_select "#plan-member-#{@editor.person.id}", text: /Sees pay/
      assert_select "aside button", text: /pay access/, count: 0
    end

    should "be told to ask a tenant admin when no one left can see pay" do
      ActsAsTenant.with_tenant(@tenant) do
        call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: account(name: "Sam Second").person.id,
                                                               role: "editor")
        @editor.person.update!(status: "inactive")
      end
      get plan_path(@plan_id)
      assert_select "aside", text: /Ask a tenant admin to restore the right/
    end

    should "not be sent to a tenant admin who can't help, on a plan frozen for want of editors" do
      ActsAsTenant.with_tenant(@tenant) { @editor.person.update!(status: "inactive") }
      get plan_path(@plan_id)
      assert_select "aside", text: /Ask a tenant admin/, count: 0
    end
  end

  should "show a right a tenant admin restored as theirs, so a holder can withdraw it from the others" do
    ActsAsTenant.with_tenant(@tenant) do
      @second = account(name: "Sam Second")
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @second.person.id, role: "editor")
      @editor.person.update!(status: "inactive")
      call(Operations::TeamPlanning::RestoreSeePay, @outsider, plan_id: @plan_id)
    end
    sign_in @second.user
    get plan_path(@plan_id)

    assert_select "#plan-member-#{@second.person.id}", text: /Restored by Ada Admin, a tenant admin, on 1 November 2026/
    assert_select "aside", text: /Ask a tenant admin/, count: 0
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path
    patch plan_see_pay_path(@plan_id, @outsider.person.id)
    assert_response :not_found
  end

  private

  def sees_pay?(account) = ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find(@plan_id).sees_pay?(account.person.id) }

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end
end
