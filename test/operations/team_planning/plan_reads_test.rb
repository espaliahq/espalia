# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::PlanReadsTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7
    level = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :member, team_planner: true,
                                     person: create(:person, tenant: @tenant, name: "Edie Marsh"))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Vic Arden"))
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed",
                            title: "Engineer", manager_id: @editor.person_id)
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0, role: "Lead")
      structure.add_unit_owner(@payments, @ada.id, effective_on: "2026-02-01")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, as: @editor, name: "Next year", base_on: BASE_ON.iso8601)[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, as: @editor, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
  end

  def call(operation, as:, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def read(operation, as: @viewer) = call(operation, as:, plan_id: @plan_id)

  should "give a member the plan, with their own role" do
    assert_equal({ plan_id: @plan_id, name: "Next year", base_on: "2026-03-02", role: "viewer", frozen: false },
                 read(Operations::TeamPlanning::Plan))
    assert_equal "editor", read(Operations::TeamPlanning::Plan, as: @editor)[:role]
  end

  should "say a plan is frozen once its editors have all left" do
    ActsAsTenant.with_tenant(@tenant) { @editor.person.update!(status: "inactive") }

    assert read(Operations::TeamPlanning::Plan)[:frozen]
  end

  should "name each member, and a forgotten one as a former member" do
    assert_equal [ [ "Edie Marsh", "editor" ], [ "Vic Arden", "viewer" ] ],
                 read(Operations::TeamPlanning::PlanMembers)[:members].map { [ it[:name], it[:role] ] }

    ActsAsTenant.with_tenant(@tenant) do
      @editor.person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
    end
    assert_includes read(Operations::TeamPlanning::PlanMembers)[:members].pluck(:name), Person::FORMER_MEMBER
  end

  should "list members by role, then name" do
    ActsAsTenant.with_tenant(@tenant) do
      @aaron = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Aaron Bell"))
    end
    call(Operations::TeamPlanning::AddPlanMember, as: @editor, plan_id: @plan_id, person_id: @aaron.person_id, role: "editor")

    assert_equal [ "Aaron Bell", "Edie Marsh", "Vic Arden" ], read(Operations::TeamPlanning::PlanMembers)[:members].pluck(:name)
  end

  should "give the baseline by id, with the names in one map beside it" do
    map = read(Operations::TeamPlanning::Baseline)

    assert_equal [ @plan_id, "2026-03-02", "2026-03-01" ], map.values_at(:plan_id, :base_on, :known_on)
    assert_equal [ { id: @payments, name: "Payments", owner_ids: [ @ada.id ] } ],
                 map[:units].map { it.slice(:id, :name, :owner_ids) }
    ada = map[:people].find { it[:id] == @ada.id }
    assert_equal [ "Engineer", @editor.person_id ], ada.values_at(:title, :manager_id)
    assert_equal [ { unit_id: @payments, allocation: 1.0, role: "Lead" } ], ada[:memberships]
    assert_equal({ @ada.id => "Ada Quill", @editor.person_id => "Edie Marsh" }, map[:names])
    assert_not_includes map[:people].to_json, "Ada Quill"
  end

  should "name every id the baseline uses, one it can't find as a former member" do
    stranger = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        .change_manager(@ada.id, stranger, **ESPALIA, effective_on: "2026-02-01")
    end

    assert_equal Person::FORMER_MEMBER, read(Operations::TeamPlanning::Baseline)[:names][stranger]
  end

  should "read as an unknown plan to anyone outside it, a tenant admin included" do
    [ Operations::TeamPlanning::Plan, Operations::TeamPlanning::PlanMembers, Operations::TeamPlanning::Baseline ].each do |op|
      error = assert_raises(Operations::Base::ParameterError) { read(op, as: @admin) }
      assert_equal "No such plan", error.message
    end
  end
end
