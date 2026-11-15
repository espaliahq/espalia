# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::RebaseTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, data) = map.with(people: map.people.map { it.id == data[:subject_id] ? it.with(title: data[:title]) : it })
    def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && change.fact == "title")

    def self.read_from(map, subject_id:, facet: self.facet)
      person = map.people.find { it.id == subject_id }
      { title: person.title } if person
    end
  end

  setup do
    @tenant = create(:tenant)
    @org = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    squads = SecureRandom.uuid_v7
    @payments, @platform = Array.new(2) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: squads, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: squads, effective_on: "2026-01-01")
      [ @ada, @brook ].each do
        @org.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        @org.set_membership(it.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end

      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
      handler.add_member(@plan_id, @viewer.person_id, role: "viewer")
      @q1 = fork("Q1", parent_id: @plan_id, relation: "then", ends_on: "2026-06-30")
      @lean = fork("Lean Q1", parent_id: @q1, relation: "instead")
    end
  end

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@editor))

  def fork(name, parent_id:, relation:, **period)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, **period) }
  end

  def plan(kind, subject_id, scenario_id = @q1, **end_state)
    as_tenant { handler.set_change(@plan_id, kind, scenario_id:, subject_id:, end_state:) }
  end

  def on(time, &) = travel_to(time) { as_tenant(&) }

  def call(operation, as: @editor, tenant: @tenant, **params)
    as_tenant(tenant) { "Operations::TeamPlanning::#{operation}".constantize.call(context: context_for(as), params:) }
  end

  def preview(as: @editor) = call(:RebasePreview, as:, plan_id: @plan_id)

  def rebase(base_on = BASE_ON.iso8601, as: @editor) = call(:RebasePlan, as:, plan_id: @plan_id, base_on:)

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  def brook_change = call(:Status, plan_id: @plan_id, scenario_id: @q1)[:statuses].find { it[:subject_id] == @brook.id }[:change_id]

  def brook_conflicts(change_id = brook_change)
    [ @q1, @lean ].map { { scenario_id: it, subject_id: @brook.id, facet: "title", change_id: } }
  end

  def drift_brook
    plan(TitleSet, @ada.id, title: "Senior Engineer")
    plan(TitleSet, @brook.id, title: "Lead Engineer")
    on(Time.utc(2026, 3, 20, 9)) { @org.change_title(@brook.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-20") }
    travel_to Time.utc(2026, 3, 25, 9)
  end

  should "preview the drift, each scenario's counts and the conflicts an update would carry" do
    drift_brook
    on(Time.utc(2026, 3, 22, 9)) { @org.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-22") }
    travel_to Time.utc(2026, 3, 25, 9)
    result = preview

    assert_equal({ plan_id: @plan_id, base_on: "2026-03-02", to: "2026-03-25",
                   scenarios: [ { scenario_id: @plan_id, done: 0, pending: 0, conflicting: 0 },
                                { scenario_id: @q1, done: 1, pending: 0, conflicting: 1 },
                                { scenario_id: @lean, done: 1, pending: 0, conflicting: 1 } ],
                   conflicts: brook_conflicts, names: { @brook.id => "Brook Tamsin" } }, result.except(:drift))
    assert_equal call(:Drift, plan_id: @plan_id).except(:plan_id), result[:drift]
    assert_equal [ [ @brook.id, "Staff Engineer" ], [ @ada.id, "Senior Engineer" ] ],
                 result[:drift][:changes].map { [ it[:person_id], it[:after]["title"] ] }
    assert_equal({ "from" => "2026-03-01", "names" => "Brook Tamsin" },
                 { "from" => result[:drift][:from], "names" => result[:drift][:names][@brook.id] })
  end

  should "count a plan-only change in no scenario's work, though status lists it" do
    drift_brook
    call(:SetRule, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments, rule: "on_cost",
                   value: { "model" => "flat", "params" => { "percent" => "10" } })

    assert_equal({ scenario_id: @q1, done: 0, pending: 1, conflicting: 1 }, preview[:scenarios].find { it[:scenario_id] == @q1 })
    assert_equal [ "plan_only" ], call(:Status, plan_id: @plan_id, scenario_id: @q1)[:statuses].select { it[:facet] == "rule:on_cost" }.pluck(:status)
  end

  should "update the plan to today, record the conflicts, and start the first step on the new base" do
    drift_brook
    expected = brook_conflicts

    assert_equal({ plan_id: @plan_id, base_on: "2026-03-25", previous_base_on: "2026-03-02", conflicts: expected }, rebase)
    assert_equal "2026-03-25", call(:Scenarios, plan_id: @plan_id)[:scenarios].find { it[:scenario_id] == @q1 }[:starts_on]

    statuses = call(:Status, plan_id: @plan_id, scenario_id: @q1)[:statuses].index_by { it[:subject_id] }
    assert_equal [ "conflicting", "2026-03-25" ], statuses[@brook.id].values_at(:status, :since).map(&:to_s)
    assert_equal "pending", statuses[@ada.id][:status].to_s
    assert_equal "rebase", call(:History, plan_id: @plan_id, scenario_id: @plan_id)[:entries].last[:action]
  end

  should "refuse a base already today or still to come, and an update since the preview was read" do
    travel_to Time.utc(2026, 3, 25, 9)
    rebase
    assert_equal "This plan already stands on today, 2026-03-25", refusal { preview }
    assert_equal "This plan already stands on today, 2026-03-25", refusal { rebase("2026-03-25") }

    travel_to Time.utc(2026, 3, 30, 9)
    assert_equal "This plan has moved since you looked: it now stands on 2026-03-25", refusal { rebase }

    later = SecureRandom.uuid_v7
    as_tenant { handler.create_plan(later, name: "Later", base_on: Date.new(2026, 6, 1)) }
    assert_equal "This plan stands on 2026-06-01, still to come: it already reads the Org Graph as known now",
                 refusal { call(:RebasePreview, plan_id: later) }
  end

  should "refuse a preview the plan is updated under, rather than counts read over two bases" do
    repository = TeamPlanning::Repository.new
    loads = 0
    update = -> { handler.rebase_plan(@plan_id, base_on: "2026-03-24", expected_base_on: BASE_ON) }
    repository.define_singleton_method(:load_plan) do |id|
      update.call if (loads += 1) == 2
      super(id)
    end

    error = on(Time.utc(2026, 3, 25, 9)) do
      preview = TeamPlanning::RebasePreview.new(context: context_for(@editor), plan: TeamPlanningPlan.find(@plan_id), repository:)
      assert_raises(TeamPlanning::Error) { preview.call }
    end
    assert_equal "This plan was updated while you looked: preview it again", error.message
  end

  should "carry a conflict only in the scenario it was read in, and not to a change made after the read" do
    drift_brook
    plan(TitleSet, @brook.id, @lean, title: "Principal Engineer")
    q1_change = brook_change
    plan(TitleSet, @brook.id, @q1, title: "Principal Engineer")
    as_tenant do
      handler.rebase_plan(@plan_id, base_on: "2026-03-25", expected_base_on: BASE_ON,
                                    conflicts: [ { scenario_id: @q1, subject_id: @brook.id, facet: "title", change_id: q1_change } ])
    end

    [ @q1, @lean ].each do |scenario_id|
      brook = call(:Status, plan_id: @plan_id, scenario_id:)[:statuses].find { it[:subject_id] == @brook.id }
      assert_equal [ "pending", nil ], brook.values_at(:status, :since).map { it&.to_s }, scenario_id
    end
  end

  should "refuse a preview and an update that would leave the first step ending before today, naming it" do
    travel_to Time.utc(2026, 7, 2, 9)
    assert_equal "Q1 ends on 2026-06-30, before 2026-07-02: end it later or remove it first", refusal { preview }
    assert_equal "Q1 ends on 2026-06-30, before 2026-07-02: end it later or remove it first", refusal { rebase }
  end

  should "name a conflict an earlier update carried, though the drift since no longer holds its subject" do
    drift_brook
    rebase
    travel_to Time.utc(2026, 3, 30, 9)
    result = preview

    assert_empty result[:drift][:changes]
    assert_equal [ @brook.id ], result[:conflicts].map { it[:subject_id] }.uniq
    assert_equal({ @brook.id => "Brook Tamsin" }, result[:names])
  end

  should "bring in someone who joined in the window, and keep someone who left unresolved" do
    hire = as_tenant { create(:person, tenant: @tenant, name: "Cass Rowe") }
    on(Time.utc(2026, 3, 10, 9)) do
      @org.record_person(hire.id, **ESPALIA, effective_on: "2026-03-10", employment_status: "employed", title: "Engineer")
      @org.set_membership(hire.id, @payments, **ESPALIA, effective_on: "2026-03-10", allocation: 1.0)
      @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-10")
    end
    [ hire, @brook ].each { |person| plan(TeamPlanning::Events::AssignmentSet, person.id, placements: [ { unit_id: @platform, allocation: 1.0 } ]) }
    unresolved = -> { call(:ScenarioMap, plan_id: @plan_id, scenario_id: @q1)[:unresolved].to_h { [ it[:person_id], it[:why] ] } }
    assert_equal({ hire.id => "joined after the base date" }, unresolved.call)

    travel_to Time.utc(2026, 3, 25, 9)
    rebase
    assert_equal({ @brook.id => "has left" }, unresolved.call)
  end

  should "let a viewer preview but not update, and refuse anyone outside the plan or the tenant" do
    travel_to Time.utc(2026, 3, 25, 9)
    assert_equal "2026-03-25", preview(as: @viewer)[:to]
    assert_equal "No such plan", refusal { rebase(as: @viewer) }
    assert_equal "No such plan", refusal { preview(as: @outsider) }
    assert_equal "No such plan", refusal { rebase(as: @outsider) }

    other = create(:tenant)
    admin = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }
    assert_equal "No such plan", refusal { call(:RebasePreview, as: admin, tenant: other, plan_id: @plan_id) }
    assert_equal "No such plan", refusal { call(:RebasePlan, as: admin, tenant: other, plan_id: @plan_id, base_on: BASE_ON.iso8601) }
  end
end
