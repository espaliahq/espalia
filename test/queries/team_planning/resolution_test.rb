# frozen_string_literal: true

require "test_helper"

class TeamPlanning::ResolutionTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  BASE_ON = Date.new(2026, 3, 2)

  # Two test-only kinds, one facet each, standing in for those 3.3 to 3.7 add.
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, data) = TeamPlanning::ResolutionTest.set_person(map, data, :title)
  end

  class SiteSet < TeamPlanning::Events::Change
    def self.facet = "site"
    def self.apply_to(map, data) = TeamPlanning::ResolutionTest.set_person(map, data, :site)
  end

  def self.set_person(map, data, field)
    map.with(people: map.people.map { it.id == data[:subject_id] ? it.with(field => data[field]) : it })
  end

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        .record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer", site: "Leeds")

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
      @q1 = fork(@plan_id, "then", "Q1", ends_on: "2026-06-30")
      @lean = fork(@q1, "instead", "Lean Q1")
      @q2 = fork(@q1, "then", "Q2", ends_on: "2026-09-30")
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler(as = @planner) = TeamPlanning::CommandHandler.new(actor: context_for(as))

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set(kind, scenario_id, **end_state)
    as_tenant { handler.set_change(@plan_id, kind, scenario_id:, subject_id: @ada.id, end_state:) }
  end

  def resolve(scenario_id, as: @planner, names: false)
    as_tenant do
      reader = TeamPlanning::Resolution.new(context: context_for(as), plan: TeamPlanningPlan.find(@plan_id), scenario_id:)
      names ? reader.call : reader.structure
    end
  end

  def ada(scenario_id) = resolve(scenario_id).people.sole.then { [ it.title, it.site ] }

  should "resolve the root to the baseline, untouched" do
    as_tenant do
      expected = TeamPlanning::Baseline.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id)).structure
      assert_equal expected, resolve(@plan_id)
    end
  end

  should "carry a step's change down to the next step, and leave the scenarios before it as they were" do
    set(TitleSet, @q1, title: "Senior Engineer")

    assert_equal [ "Engineer", "Leeds" ], ada(@plan_id)
    assert_equal [ "Senior Engineer", "Leeds" ], ada(@q1)
    assert_equal [ "Senior Engineer", "Leeds" ], ada(@q2)
  end

  should "start an alternative as its parent plus its own differences" do
    set(TitleSet, @q1, title: "Senior Engineer")
    set(SiteSet, @q1, site: "York")
    set(TitleSet, @lean, title: "Staff Engineer")

    assert_equal [ "Staff Engineer", "York" ], ada(@lean)
    assert_equal [ "Senior Engineer", "York" ], ada(@q1), "the parent keeps its own change"
  end

  should "let an alternative set back what its parent's parent had" do
    set(TitleSet, @q1, title: "Senior Engineer")
    set(TitleSet, @lean, title: "Engineer")

    assert_equal [ "Engineer", "Leeds" ], ada(@lean)
  end

  should "take the last change for a subject and facet, later in the chain or later in one scenario" do
    set(TitleSet, @q1, title: "Senior Engineer")
    set(TitleSet, @q1, title: "Lead Engineer")
    set(TitleSet, @q2, title: "Staff Engineer")

    assert_equal "Lead Engineer", ada(@q1).first
    assert_equal "Staff Engineer", ada(@q2).first
  end

  should "land changes to two facets of one subject together" do
    set(TitleSet, @q1, title: "Senior Engineer")
    set(SiteSet, @q2, site: "York")
    set(TitleSet, @q2, title: "Staff Engineer")
    set(SiteSet, @q1, site: "Hull")

    assert_equal [ "Staff Engineer", "York" ], ada(@q2)
  end

  should "drop a removed scenario's changes from every resolution" do
    set(TitleSet, @lean, title: "Staff Engineer")
    as_tenant { handler.remove_scenario(@plan_id, @lean) }
    lean_again = as_tenant { fork(@q1, "instead", "Lean Q1 again") }

    assert_equal [ "Engineer", "Leeds" ], ada(lean_again)
  end

  should "join names last, and name a forgotten person a former member" do
    assert_empty resolve(@q1).names
    assert_equal "Ada Quill", resolve(@q1, names: true).name_of(@ada.id)

    as_tenant { @ada.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }
    assert_equal Person::FORMER_MEMBER, resolve(@q1, names: true).name_of(@ada.id)
  end

  should "refuse a scenario the plan doesn't have" do
    error = assert_raises(TeamPlanning::Error) { resolve(SecureRandom.uuid_v7) }
    assert_equal "This plan has no such scenario", error.message
  end

  should "let a viewer resolve, and refuse anyone outside the plan, a tenant admin included" do
    viewer, outsider = as_tenant do
      Array.new(2) { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
    end
    as_tenant { handler.add_member(@plan_id, viewer.person.id, role: "viewer") }
    set(TitleSet, @q1, title: "Senior Engineer")

    assert_equal "Senior Engineer", resolve(@q1, as: viewer).people.sole.title
    assert_raises(Pundit::NotAuthorizedError) { resolve(@q1, as: outsider) }
  end

  should "refuse another tenant's admin" do
    other = create(:tenant)
    stranger = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }

    assert_raises(Pundit::NotAuthorizedError) { resolve(@q1, as: stranger) }
  end
end
