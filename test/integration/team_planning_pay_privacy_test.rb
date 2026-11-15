# frozen_string_literal: true

require "test_helper"

# Actual pay a plan holds reaches only members with the see-pay right
# (#317). This walks every Team Planning read as a viewer and as an editor
# without the right, and looks for the amount in what they get, in the log,
# in the read models and in the event store. A new read joins on its own.
class TeamPlanningPayPrivacyTest < ActiveSupport::TestCase
  AMOUNT = "92417"

  class Hiring < TeamPlanning::ForecastKind
    def self.rule_name = "test_privacy_hiring"
    def self.description = "A fixed forecast cost"
    def self.default = {}

    def self.forecast(frame) = [ frame.row(unit_id: nil, headcount: 1r, cost: { "AUD" => 1000r }) ]
  end

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

  should "show a viewer and an editor without the see-pay right no pay from any read, in a scenario or in Today" do
    [ @q1, @plan_id ].each { assert_no_pay_read(it) }
  end

  should "price Today's yearly run rate from held pay for a holder, and never for anyone else" do
    holder = call(Operations::TeamPlanning::Cost, @holder, plan_id: @plan_id, scenario_id: @plan_id)

    assert_equal [ "run_rate", "band_ranges", { scenario: 1 } ], holder.values_at(:basis, :pay_view, :actual_pay_seats)
    assert_includes holder.to_json, AMOUNT
    [ @editor, @viewer ].each do |account|
      other = call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id: @plan_id)

      assert_equal [ "run_rate", "band_midpoints" ], other.values_at(:basis, :pay_view)
      assert_not_includes other.keys, :actual_pay_seats
      assert_not_includes other.to_json, AMOUNT
    end
  end

  context "the actual, planned and forecast split" do
    setup do
      @tenant.update!(hris_config: build(:tenant, :with_hibob_config).hris_config)
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      level = create(:framework_level, role_id: engineer.role_id, ordinal: 3, title: "Engineer")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .apply_facts(@ada.id, provider: "espalia", effective_on: "2026-02-01", title: "Software Engineer")
      PayBand.create!(level:, currency: "AUD", period: "year", minimum: 50_000, midpoint: 100_000, maximum: 150_000)
      ReferenceCurrency.create!(currency: "AUD")
      TeamPlanning::RuleKinds.register(Hiring)
    end

    teardown { TeamPlanning::RuleKinds.unregister(Hiring) }

    # Q1 holds 121 of the run rate's 365 days.
    should "add up a member's parts to their own total: midpoints without the right, actual pay with it, and no figure from the pay for the first" do
      { @plan_id => Rational(1), @q1 => Rational(121, 365) }.each do |scenario_id, share|
        midpoint = 100_000 * share
        forecast = scenario_id == @q1 ? 1000 : 0
        derived = BigDecimal(Integer(AMOUNT) * share, 20).to_s("F")[0, 5]

        { @editor => midpoint, @viewer => midpoint, @holder => Integer(AMOUNT) * share }.each do |account, priced|
          who = "#{account == @holder ? 'holder' : 'non-holder'} in #{scenario_id == @plan_id ? 'Today' : 'Q1'}"
          cost = call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id:)
          table = call(Operations::TeamPlanning::ScenarioCosts, account, plan_id: @plan_id)[:scenarios].find { it[:scenario_id] == scenario_id }

          assert_split(cost[:total], priced + forecast, who)
          assert_equal cost[:total], table[:total], who
          assert_equal(forecast, call(Operations::TeamPlanning::Forecast, account, plan_id: @plan_id, scenario_id:)[:rows].sum { BigDecimal(it[:cost]["AUD"]) }, who)
          if account == @holder
            assert_includes cost.to_json, derived, who
            next
          end

          [ cost, table, call(Operations::TeamPlanning::Forecast, account, plan_id: @plan_id, scenario_id:) ].each do |payload|
            assert_not_includes payload.to_json, derived, who
          end
        end
      end
    end
  end

  should "move a pay change across a split with its value still sealed and read by holders alone" do
    call(Operations::TeamPlanning::SetPlannedLevel, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
    split = call(Operations::TeamPlanning::SplitScenario, @holder, plan_id: @plan_id, scenario_id: @q1, event_ids: [ @event_id ], name: "Agreed")
    agreed = split[:agreed_id]

    assert_equal [ @event_id ], split[:moved_event_ids]
    assert_not_includes split.to_json, AMOUNT
    assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: agreed).to_json, AMOUNT
    assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @q1).to_json, AMOUNT
    [ agreed, @q1 ].each { assert_no_pay_read(it) }
    assert_not_includes @log.string, AMOUNT
    assert_not_includes event_store_text, AMOUNT
  end

  should "list a pay change to an editor without the right by its facet alone, and let them split it across sealed" do
    call(Operations::TeamPlanning::SetPlannedLevel, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
    needs = call(Operations::TeamPlanning::SplitNeeds, @editor, plan_id: @plan_id, scenario_id: @q1)
    pay = needs[:changes].find { it[:facet] == "data:pay" }

    assert_equal({ event_id: @event_id, subject_id: @ada.id, facet: "data:pay", needs: [] }, pay)
    assert_not_includes needs.to_json, AMOUNT

    split = call(Operations::TeamPlanning::SplitScenario, @editor, plan_id: @plan_id, scenario_id: @q1, event_ids: [ @event_id ], name: "Agreed")

    assert_equal [ @event_id ], split[:moved_event_ids]
    assert_not_includes split.to_json, AMOUNT
    assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: split[:agreed_id]).to_json, AMOUNT
    [ split[:agreed_id], @q1 ].each { assert_no_pay_read(it) }
    assert_not_includes @log.string, AMOUNT
  end

  should "read pay as its field alone where an override inherits it off the parent's map, to a holder too" do
    TeamPlanningOverride.where(scenario_id: @plan_id).delete_all

    { "holder" => @holder, "viewer" => @viewer, "editor" => @editor }.each do |who, account|
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

  should "read pay plan only to every member, never as Org Graph work still to do" do
    { "holder" => @holder, "viewer" => @viewer, "editor" => @editor }.each do |who, account|
      pay = call(Operations::TeamPlanning::Status, account, plan_id: @plan_id, scenario_id: @q1)[:statuses].find { it[:facet] == "data:pay" }

      assert_equal [ "plan_only", nil, [] ], pay.values_at(:status, :since, :sources), who
      assert_empty call(Operations::TeamPlanning::Attention, account, plan_id: @plan_id, scenario_id: @q1)[:items].select { it[:facet] == "data:pay" }, who
    end
  end

  should "warn an editor without the right, by count alone, that removing a scenario removes pay they can't see" do
    set_pay(@q1)
    notice = Operations::TeamPlanning::RemoveScenario.approval_notice(context: context_for(@editor), params: { plan_id: @plan_id, scenario_id: @q1 })

    assert_equal "This scenario holds 1 change to pay you can't see. Removing it removes that too.", notice
    assert_nil Operations::TeamPlanning::RemoveScenario.approval_notice(context: context_for(@holder), params: { plan_id: @plan_id, scenario_id: @q1 })
  end

  should "let an editor without the right remove a scenario, leaving the holder's other pay intact and unread by them" do
    result = call(Operations::TeamPlanning::RemoveScenario, @editor, plan_id: @plan_id, scenario_id: @q1)

    assert_not_includes result.to_json, AMOUNT
    assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @plan_id).to_json, AMOUNT
    assert_not_includes call(Operations::TeamPlanning::ScenarioMap, @editor, plan_id: @plan_id, scenario_id: @plan_id).to_json, AMOUNT
    assert_not_includes @log.string, AMOUNT
    removed = Rails.configuration.event_store.read.of_type(TeamPlanning::Events::ScenarioRemoved).last
    assert_equal [ @q1, @editor.person_id ], removed.data.values_at(:scenario_id, :removed_by_id)
    assert_equal Time.current, removed.timestamp
  end

  private

  def assert_no_pay_read(scenario_id)
    { "viewer" => @viewer, "editor" => @editor }.each do |who, account|
      READS.call.each do |operation|
        tool = Operations::Registry.tool_name_for(operation)
        output = begin
          call(operation, account, **params_for(operation, scenario_id:)).to_json
        rescue Operations::Base::ParameterError => e
          e.message
        end
        assert_not_includes output, AMOUNT, "#{tool} as #{who} in #{scenario_id == @plan_id ? 'Today' : scenario_id}"
      end
    end
  end

  def assert_split(total, expected, who)
    parts = total[:parts].values_at(:actual, :planned, :forecast).sum { BigDecimal(it[:converted]) }
    assert_in_delta expected, BigDecimal(total[:scenario][:converted]), 1e-9, who
    assert_in_delta expected, parts, 1e-9, who
  end

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

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

  def params_for(operation, scenario_id: @q1)
    { plan_id: @plan_id, scenario_id:, person_id: @ada.id, subject_id: @ada.id, facet: "data:pay", event_id: @event_id }
      .slice(*operation.parameters.keys)
  end

  def call(operation, account, **params)
    operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
  end
end
