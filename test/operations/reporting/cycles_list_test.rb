# frozen_string_literal: true

require "test_helper"

class Operations::Reporting::CyclesListTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @framework = create(:framework_state, tenant: @tenant, name: "Engineering Ladder")
      @other_framework = create(:framework_state, tenant: @tenant, name: "Product Ladder")

      @open = create(:assessment_cycle, tenant: @tenant, framework_id: @framework.framework_id,
        name: "H2 2026", opened_at: Time.utc(2026, 7, 1))
      @closed = create(:assessment_cycle, :closed, tenant: @tenant, framework_id: @framework.framework_id,
        name: "H1 2026", opened_at: Time.utc(2026, 1, 1), closed_at: Time.utc(2026, 6, 30))
      @elsewhere = create(:assessment_cycle, tenant: @tenant, framework_id: @other_framework.framework_id,
        name: "Product H2", opened_at: Time.utc(2026, 8, 1))

      @manager_user = create(:user)
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report = create(:person, tenant: @tenant, name: "Report", manager: @manager)
      @outsider = create(:person, tenant: @tenant, name: "Outsider")

      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @open, person_id: @report.id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @open, person_id: @outsider.id)
      create(:assessment_cycle_enrollment, :concluded, tenant: @tenant, cycle: @closed, person_id: @report.id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @elsewhere, person_id: @outsider.id)
    end
    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
  end

  def call_op(context:, params: {})
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Reporting::CyclesList.call(context: context, params: params)
    end
  end

  def member_context(name, role: :member)
    user = create(:user)
    tenant_user = ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: user.email, name: name)
      yield person if block_given?
      create(:tenant_user, tenant: @tenant, user: user, person: person, role: role)
    end
    AuthorizationContext.new(user: user, tenant_user: tenant_user, person: tenant_user.person)
  end

  should "give an admin every cycle, newest first, with whole-cycle counts" do
    cycles = call_op(context: member_context("Admin", role: :admin))[:cycles]

    assert_equal [ "Product H2", "H2 2026", "H1 2026" ], cycles.map { |c| c[:name] }
    assert_equal 2, cycles.find { |c| c[:name] == "H2 2026" }[:participant_count]
  end

  should "describe each cycle, closed ones with their close date" do
    closed = call_op(context: @manager_ctx)[:cycles].find { |c| c[:id] == @closed.cycle_id }

    assert_equal "closed", closed[:status]
    assert_equal "2026-01-01T00:00:00Z", closed[:opened_at]
    assert_equal "2026-06-30T00:00:00Z", closed[:closed_at]
    assert_equal({ id: @framework.framework_id, name: "Engineering Ladder" }, closed[:framework])
    assert_equal 1, closed[:framework_version]
  end

  should "give a manager only the cycles their subtree is in, counting only that subtree" do
    cycles = call_op(context: @manager_ctx)[:cycles]

    assert_equal [ @open.cycle_id, @closed.cycle_id ], cycles.map { |c| c[:id] }
    assert_equal 1, cycles.first[:participant_count], "the outsider in H2 2026 is not counted"
  end

  should "give a skip-level manager their whole subtree's cycles" do
    ctx = member_context("Skip") { |skip| @manager.update!(manager: skip) }

    assert_equal [ @open.cycle_id, @closed.cycle_id ], call_op(context: ctx)[:cycles].map { |c| c[:id] }
  end

  should "leave out a cycle the subtree withdrew from" do
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentCycleEnrollment.find_by!(cycle_id: @open.cycle_id, person_id: @report.id)
        .update!(status: "withdrawn", withdrawn_at: Time.current, withdrawal_reason: "manual")
    end

    assert_equal [ @closed.cycle_id ], call_op(context: @manager_ctx)[:cycles].map { |c| c[:id] }
  end

  should "give a member with no reports an empty list" do
    assert_empty call_op(context: member_context("Loner"))[:cycles]
  end

  should "filter by status and framework" do
    admin = member_context("Admin", role: :admin)

    assert_equal [ "H1 2026" ], call_op(context: admin, params: { status: "closed" })[:cycles].map { |c| c[:name] }
    assert_equal [ "Product H2" ],
      call_op(context: admin, params: { framework_id: @other_framework.framework_id })[:cycles].map { |c| c[:name] }
  end

  should "deny someone outside the tenant" do
    outsider = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { call_op(context: outsider) }
  end
end
