# frozen_string_literal: true

require "test_helper"

# Actual pay a plan holds reaches only members with the see-pay right
# (#317). This walks every Team Planning read as a viewer and as an editor
# without the right, and looks for the amount in what they get, in the log,
# in the read models and in the event store. A new read joins on its own.
class TeamPlanningPayPrivacyTest < ActiveSupport::TestCase
  AMOUNT = "92417"
  SCOPED = { in: "71263", half_actual: "64000", half_full: "88000" }.freeze
  SCOPED_OUT = "83519"

  setup do
    travel_to Time.utc(2026, 2, 1, 9)
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    @ada = @subject = create(:person, tenant: @tenant, name: "Ada Quill")
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

  context "in a plan scoped to chosen units" do
    setup do
      @tenant.update!(hris_config: build(:tenant, :with_hibob_config).hris_config)
      people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      departments = SecureRandom.uuid_v7
      @payments, @sales = Array.new(2) { SecureRandom.uuid_v7 }
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: departments, effective_on: "2025-01-01")
      structure.create_unit(@sales, "Sales", level_id: departments, effective_on: "2025-01-01")

      family = create(:framework_role_family, name: "Engineering")
      engineer = create(:framework_role, code: "E", name: "Software Engineer", role_family_id: family.role_family_id)
      e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      PayBand.create!(level: e5, currency: "AUD", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "AUD")

      @in, @half_actual, @half_full, @out = %w[In Halfactual Halffull Out].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      { @in => 1.0, @half_actual => 0.5, @half_full => 0.5, @out => 1.0 }.each do |person, fte|
        people.record_person(person.id, provider: "espalia", effective_on: "2026-01-01", employment_status: "employed",
                                        title: "Software Engineer", level: "5", fte:)
      end
      { @in => { @payments => 1.0 }, @half_actual => { @payments => 0.5, @sales => 0.5 },
        @half_full => { @payments => 0.5, @sales => 0.5 }, @out => { @sales => 1.0 } }.each do |person, places|
        places.each { |unit, allocation| people.set_membership(person.id, unit, provider: "espalia", effective_on: "2026-01-01", allocation:) }
      end

      @plan_id = call(Operations::TeamPlanning::CreatePlan, @holder, name: "Payments next year", base_on: "2026-03-02", unit_ids: [ @payments ])[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @holder, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
      call(Operations::TeamPlanning::AddPlanMember, @holder, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
      [ @plan_id, @q1 ].each do |scenario_id|
        hold_pay(scenario_id, @in, SCOPED[:in], "full_time")
        hold_pay(scenario_id, @half_actual, SCOPED[:half_actual], "actual")
        hold_pay(scenario_id, @half_full, SCOPED[:half_full], "full_time")
      end
      @subject = @in
      @event_id = call(Operations::TeamPlanning::History, @holder, plan_id: @plan_id, scenario_id: @q1)[:entries]
                  .find { it[:facet] == "data:pay" && it[:subject_id] == @in.id }[:event_id]
    end

    should "show a holder the pay it holds for people in scope, so the walk below can see it" do
      [ @plan_id, @q1 ].each do |scenario_id|
        map = call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id:).to_json
        SCOPED.each_value { assert_includes map, it }
      end
    end

    should "show a viewer and an editor without the see-pay right no pay from any read, in a scenario or in Today" do
      [ @q1, @plan_id ].each { assert_no_pay_read(it, amounts: SCOPED.values) }
    end

    should "count a holder the in-scope share of actual pay, and keep everyone else on midpoints for the same share" do
      held = payments_seats(@holder)
      assert_equal %w[actual actual actual], [ @in, @half_actual, @half_full ].map { held[it.id][:pay_source] }
      assert_equal 71_263r, held[@in.id][:base].to_r
      assert_equal 64_000r * 0.5r, held[@half_actual.id][:base].to_r, "actual pay is what they earn: FTE leaves it alone"
      assert_equal 88_000r * 0.5r * 0.5r, held[@half_full.id][:base].to_r, "a full-time figure scales by FTE as well as the share"

      [ @editor, @viewer ].each do |account|
        midpoints = payments_seats(account)
        assert_equal %w[band_midpoint band_midpoint band_midpoint], [ @in, @half_actual, @half_full ].map { midpoints[it.id][:pay_source] }
        assert_equal [ 100_000r, 25_000r, 25_000r ], [ @in, @half_actual, @half_full ].map { midpoints[it.id][:base].to_r }
      end
    end

    should "refuse pay for someone outside the plan's units, in words that don't name them" do
      error = assert_raises(Operations::Base::ParameterError) { hold_pay(@q1, @out, SCOPED_OUT, "full_time") }
      [ @out.id, @out.name ].each { assert_not_includes error.message, it }
      assert_not_includes event_store_text, SCOPED_OUT
    end

    should "keep pay held for someone the Org Graph moves out of the plan's units out of every read, and their id out of the plan's figures" do
      moved = create(:person, tenant: @tenant, name: "Moved Quill")
      people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      people.record_person(moved.id, provider: "espalia", effective_on: "2026-01-01", employment_status: "employed",
                                     title: "Software Engineer", level: "5", fte: 1.0)
      people.set_membership(moved.id, @payments, provider: "espalia", effective_on: "2026-01-01", allocation: 1.0)
      hold_pay(@q1, moved, SCOPED_OUT, "full_time")
      assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @q1).to_json, SCOPED_OUT

      people.move_membership(moved.id, @payments, @sales, effective_on: "2026-02-01")
      @subject = moved
      { "holder" => @holder, "editor" => @editor, "viewer" => @viewer }.each do |who, account|
        READS.call.each do |operation|
          output = begin
            call(operation, account, **params_for(operation, scenario_id: @q1)).to_json
          rescue Operations::Base::ParameterError => e
            e.message
          end
          assert_not_includes output, SCOPED_OUT, "#{Operations::Registry.tool_name_for(operation)} as #{who}"
        end
        figures = [ call(Operations::TeamPlanning::ScenarioMap, account, plan_id: @plan_id, scenario_id: @q1),
                    call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments),
                    call(Operations::TeamPlanning::Baseline, account, plan_id: @plan_id),
                    call(Operations::TeamPlanning::Timeline, account, plan_id: @plan_id, scenario_id: @q1),
                    call(Operations::TeamPlanning::ScenarioCosts, account, plan_id: @plan_id) ]
        figures.each_with_index { |figure, index| assert_not_includes figure.to_json, moved.id, "figure #{index} as #{who}" }
      end
    end

    should "leave pay held for someone brought in unreadable again, to a holder too, once that change is undone" do
      call(Operations::TeamPlanning::SetAssignment, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @out.id,
                                                             placements: [ { unit_id: @payments, allocation: 1 } ])
      brought_in = call(Operations::TeamPlanning::History, @holder, plan_id: @plan_id, scenario_id: @q1)[:entries]
                   .find { it[:subject_id] == @out.id }[:event_id]
      hold_pay(@q1, @out, SCOPED_OUT, "full_time")
      assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @q1).to_json, SCOPED_OUT

      call(Operations::TeamPlanning::UndoChange, @holder, plan_id: @plan_id, scenario_id: @q1, event_id: brought_in)
      { "holder" => @holder, "editor" => @editor, "viewer" => @viewer }.each do |who, account|
        READS.call.each do |operation|
          output = begin
            call(operation, account, **params_for(operation, scenario_id: @q1)).to_json
          rescue Operations::Base::ParameterError => e
            e.message
          end
          assert_not_includes output, SCOPED_OUT, "#{Operations::Registry.tool_name_for(operation)} as #{who}"
        end
      end
    end
  end

  private

  def assert_no_pay_read(scenario_id, amounts: [ AMOUNT ])
    { "viewer" => @viewer, "editor" => @editor }.each do |who, account|
      READS.call.each do |operation|
        tool = Operations::Registry.tool_name_for(operation)
        output = begin
          call(operation, account, **params_for(operation, scenario_id:)).to_json
        rescue Operations::Base::ParameterError => e
          e.message
        end
        amounts.each { assert_not_includes output, it, "#{tool} as #{who} in #{scenario_id == @plan_id ? 'Today' : scenario_id}" }
      end
    end
  end

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def set_pay(scenario_id)
    call(Operations::TeamPlanning::SetActualPay, @holder, plan_id: @plan_id, scenario_id:, person_id: @ada.id,
                                                          amount: AMOUNT, currency: "AUD", period: "year", basis: "full_time")
  end

  def hold_pay(scenario_id, person, amount, basis)
    call(Operations::TeamPlanning::SetActualPay, @holder, plan_id: @plan_id, scenario_id:, person_id: person.id,
                                                          amount:, currency: "AUD", period: "year", basis:)
  end

  def payments_seats(account)
    call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id: @plan_id, unit_id: @payments)[:seats][:scenario].index_by { it[:seat_id] }
  end

  # `data` is bytea, which casts to hex; escape keeps printable bytes as they
  # are and never fails on a sealed row.
  def event_store_text(planted = nil)
    sql = "SELECT encode(data, 'escape') FROM event_store_events"
    sql = "SELECT encode(convert_to('{\"amount\":\"#{planted}\"}', 'UTF8'), 'escape') UNION ALL #{sql}" if planted
    ActiveRecord::Base.connection.select_values(sql).join
  end

  def params_for(operation, scenario_id: @q1)
    { plan_id: @plan_id, scenario_id:, person_id: @subject.id, subject_id: @subject.id, facet: "data:pay", event_id: @event_id }
      .slice(*operation.parameters.keys)
  end

  def call(operation, account, **params)
    operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
  end
end
