# frozen_string_literal: true

require "test_helper"

# Actual pay a plan holds reaches only members with the see-pay right
# (#317). This walks every Team Planning read as a viewer and as an editor
# without the right, and looks for the amount in what they get, in the log,
# in the read models and in the event store. A new read joins on its own.
class TeamPlanningPayPrivacyTest < ActiveSupport::TestCase
  AMOUNT = "92417"

  setup do
    travel_to Time.utc(2026, 2, 1, 9)
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    @ada = create(:person, tenant: @tenant, name: "Ada Quill")
    OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                            .record_person(@ada.id, provider: "espalia", effective_on: "2026-02-01", employment_status: "employed", level: "3")

    @log = StringIO.new
    Rails.logger.broadcast_to(@logger = ActiveSupport::Logger.new(@log))

    @plan_id = call(Operations::TeamPlanning::CreatePlan, @holder, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, @holder, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
    call(Operations::TeamPlanning::AddPlanMember, @holder, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    [ @plan_id, @q1 ].each { set_pay(it) }
    @event_id = call(Operations::TeamPlanning::History, @holder, plan_id: @plan_id, scenario_id: @q1)[:entries].find { it[:facet] == "data:pay" }[:event_id]
    call(Operations::TeamPlanning::NoteChange, @holder, plan_id: @plan_id, scenario_id: @q1, event_id: @event_id, note: "Agreed")
  end

  teardown do
    Rails.logger.stop_broadcasting_to(@logger)
    ActsAsTenant.current_tenant = nil
  end

  READS = -> { Operations::Registry.all.select { it.name.start_with?("Operations::TeamPlanning::") && it.category == :read && it.parameters.key?(:plan_id) } }

  should "show a holder the pay it holds, so the walk below can see it" do
    assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @q1).to_json, AMOUNT
    assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @plan_id).to_json, AMOUNT
  end

  should "show a holder pay as removed once the person is forgotten" do
    PlanKeyStore.new.destroy_person(@ada.id)
    ada = call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @q1)[:people].find { it[:id] == @ada.id }

    assert_equal({ removed: true }, ada[:plan_data][:pay])
  end

  should "show a viewer and an editor without the see-pay right no pay from any read" do
    { "viewer" => @viewer, "editor" => @editor }.each do |who, account|
      READS.call.each do |operation|
        tool = Operations::Registry.tool_name_for(operation)
        output = begin
          call(operation, account, **params_for(operation)).to_json
        rescue Operations::Base::ParameterError => e
          e.message
        end
        assert_not_includes output, AMOUNT, "#{tool} as #{who}"
      end
    end
  end

  should "show a non-holder no pay where an override reads what it inherits off the parent's map" do
    TeamPlanningOverride.where(scenario_id: @plan_id).delete_all

    { "viewer" => @viewer, "editor" => @editor }.each do |who, account|
      overrides = call(Operations::TeamPlanning::Overrides, account, plan_id: @plan_id, scenario_id: @q1)
      pay = overrides[:overrides].find { it[:facet] == "data:pay" }

      assert_equal({ scenario_id: nil, end_state: { "field" => "pay" } }, pay[:inherits], who)
      assert_not_includes overrides.to_json, AMOUNT, who
    end
  end

  should "capture the log the leak check reads" do
    Rails.logger.info("probe #{AMOUNT}")

    assert_includes @log.string, AMOUNT
  end

  should "read the Team Planning tables in a form that would show a clear amount" do
    tables = ActiveRecord::Base.connection.tables.grep(/\Ateam_planning/)

    assert_predicate tables, :any?
    assert_includes ActiveRecord::Base.connection.select_values("SELECT row_to_json(t)::text FROM (SELECT '#{AMOUNT}' AS amount) t").join, AMOUNT
  end

  should "keep pay out of the log, the read models and the event store in clear" do
    assert_not_includes @log.string, AMOUNT

    tables = ActiveRecord::Base.connection.tables.grep(/\Ateam_planning/)
    tables.each do |table|
      assert_not_includes ActiveRecord::Base.connection.select_values("SELECT row_to_json(t)::text FROM #{table} t").join, AMOUNT, table
    end
    assert_not_includes event_store_text, AMOUNT
  end

  should "read the event store in a form that would show a clear amount" do
    assert_includes event_store_text(AMOUNT), AMOUNT
  end

  should "answer an editor without the right in no more than status already shows them" do
    error = assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::UndoChange, @editor, plan_id: @plan_id, scenario_id: @q1, event_id: @event_id)
    end
    assert_not_includes error.message, AMOUNT
    statuses = call(Operations::TeamPlanning::Status, @editor, plan_id: @plan_id, scenario_id: @q1).to_json
    assert_includes statuses, "data:pay"
  end

  private

  def set_pay(scenario_id)
    call(Operations::TeamPlanning::SetActualPay, @holder, plan_id: @plan_id, scenario_id:, person_id: @ada.id,
                                                          amount: AMOUNT, currency: "AUD", period: "year", basis: "full_time")
  end

  # `data` is bytea, which casts to hex; escape keeps printable bytes as they
  # are and never fails on a sealed row.
  def event_store_text(planted = nil)
    sql = "SELECT encode(data, 'escape') FROM event_store_events"
    sql = "SELECT encode(convert_to('{\"amount\":\"#{planted}\"}', 'UTF8'), 'escape') UNION ALL #{sql}" if planted
    ActiveRecord::Base.connection.select_values(sql).join
  end

  def params_for(operation)
    { plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, subject_id: @ada.id, facet: "data:pay", event_id: @event_id }
      .slice(*operation.parameters.keys)
  end

  def call(operation, account, **params)
    operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
  end
end
