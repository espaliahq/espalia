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

  should "list a removed scenario that held pay to every member as one count, with no amount or note from any read" do
    q2 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2",
                                                               ends_on: "2026-09-30")[:scenario_id]
    set_pay(q2)
    pay = call(Operations::TeamPlanning::History, @holder, plan_id: @plan_id, scenario_id: q2)[:entries].sole[:event_id]
    call(Operations::TeamPlanning::NoteChange, @holder, plan_id: @plan_id, scenario_id: q2, event_id: pay, note: "Gone with Q2")
    call(Operations::TeamPlanning::RemoveScenario, @holder, plan_id: @plan_id, scenario_id: q2)

    [ @holder, @editor, @viewer ].each do |account|
      removed = call(Operations::TeamPlanning::RemovedScenarios, account, plan_id: @plan_id)[:removed].sole
      assert_equal [ q2, "Q2", 1 ], removed.values_at(:scenario_id, :name, :changes)
      assert_not_includes removed.to_json, "Gone with Q2"
    end
    assert_no_pay_read(@q1, amounts: [ AMOUNT, "Gone with Q2" ])
  end

  should "show no pay to anyone else from any read of a step with no end date, while a holder's cost, budget and funding run over it" do
    open = SecureRandom.uuid_v7
    TeamPlanning::CommandHandler.new(actor: context_for(@holder)).fork_scenario(@plan_id, open, parent_id: @q1, relation: "then", name: "Q2")

    holder = call(Operations::TeamPlanning::Cost, @holder, plan_id: @plan_id, scenario_id: open)
    assert_equal({ starts_on: "2026-07-01", ends_on: "2027-06-30", open_ended: true, horizon_months: 12 }, holder[:period])
    assert_includes holder.to_json, AMOUNT, "a year of actual pay over the twelve months shown"
    [ Operations::TeamPlanning::Budget, Operations::TeamPlanning::Funding ].each do |operation|
      assert call(operation, @holder, plan_id: @plan_id, scenario_id: open)[:period][:open_ended]
    end

    assert_no_pay_read(open)
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

  # The figures under each timeline column ([#452](https://github.com/espaliahq/espalia/issues/452)).
  should "price the timeline's figures from held pay for a holder, as its cost read does, and never for anyone else" do
    holder = call(Operations::TeamPlanning::TimelineFigures, @holder, plan_id: @plan_id, scenario_id: @q1)

    assert_equal [ @plan_id, @q1 ], holder[:steps].pluck(:scenario_id)
    assert_equal call(Operations::TeamPlanning::Cost, @holder, plan_id: @plan_id, scenario_id: @plan_id)[:total][:scenario], holder[:steps].first[:cost]
    assert_includes holder.to_json, AMOUNT, "Today's run rate is a year of the held pay"
    [ @editor, @viewer ].each do |account|
      other = call(Operations::TeamPlanning::TimelineFigures, account, plan_id: @plan_id, scenario_id: @q1)

      assert_equal [ "band_midpoints", false ], other.values_at(:pay_view, :money)
      assert_not_includes other.to_json, AMOUNT
    end
  end

  context "the actual, planned and forecast split" do
    setup do
      @tenant.update!(hris_config: build(:tenant, :with_hibob_config).hris_config)
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      create(:framework_level, role_id: engineer.role_id, ordinal: 3, title: "Engineer")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .apply_facts(@ada.id, provider: "espalia", effective_on: "2026-02-01", title: "Software Engineer")
      # A family's band, so the walk covers a band wider than one role.
      family = create(:framework_role_family, role_family_id: engineer.role_family_id, name: "Engineering")
      PayBand.new(currency: "AUD", period: "year", minimum: 50_000, midpoint: 100_000, maximum: 150_000)
             .tap { it.match_on(role_family: family, level_ordinal: 3) }.save!
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

    # Attrition at 10% a year with 73 days to hire leaves 616.85/365 empty
    # FTE-days in Q1's 121, priced at the caller's average for the seat.
    should "price attrition at the midpoint without the right and from actual pay with it, still adding up to each member's total" do
      call(Operations::TeamPlanning::SetRule, @holder, plan_id: @plan_id, scenario_id: @plan_id, rule: "attrition", value: { "yearly_rate" => "0.1" })
      call(Operations::TeamPlanning::SetRule, @holder, plan_id: @plan_id, scenario_id: @plan_id, rule: "time_to_hire", value: { "days" => "73" })
      empty = Rational(61_685, 100 * 365) / 365
      derived = BigDecimal(Integer(AMOUNT) * empty, 20).to_s("F")[0, 5]

      { @plan_id => Rational(1), @q1 => Rational(121, 365) }.each do |scenario_id, share|
        { @editor => 100_000, @viewer => 100_000, @holder => Integer(AMOUNT) }.each do |account, yearly|
          who = "#{account == @holder ? 'holder' : 'non-holder'} in #{scenario_id == @plan_id ? 'Today' : 'Q1'}"
          attrition = scenario_id == @q1 ? -yearly * empty : 0
          cost = call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id:)
          forecast = call(Operations::TeamPlanning::Forecast, account, plan_id: @plan_id, scenario_id:)
          hiring = scenario_id == @q1 ? 1000 : 0

          assert_split(cost[:total], (yearly * share) + hiring + attrition, who)
          assert_in_delta hiring + attrition, forecast[:rows].sum { BigDecimal(it[:cost]["AUD"]) }, 1e-6, who
          next unless scenario_id == @q1

          if account == @holder
            assert_includes forecast.to_json, derived, who
          else
            [ cost, forecast ].each { assert_not_includes it.to_json, derived, who }
          end
        end
      end
    end

    # Q2 holds pay of its own, so a holder's run rate at its end is 2894 above
    # Today's: a figure that is in no one else's read.
    # Ids are stripped first, as a random one could hold any of these digits.
    should "price the run rate at a step's end from held pay for a holder alone, in the reads, the strip and the table" do
      q2 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")[:scenario_id]
      hold_pay(q2, @ada, "95311", "full_time")

      seen = { @holder => "95311", @editor => "100000", @viewer => "100000" }.to_h do |account, yearly|
        who = account == @holder ? "holder" : "non-holder"
        cost = call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id: q2)
        costs = call(Operations::TeamPlanning::ScenarioCosts, account, plan_id: @plan_id)
        row = costs[:scenarios].find { it[:scenario_id] == q2 }
        map = call(Operations::TeamPlanning::ScenarioMap, account, plan_id: @plan_id, scenario_id: q2)
        strip = Views::Plans::CostStrip.new(marks: Views::Plans::CostMarks.new(cost:, map:)).call
        cell = Views::Plans::CostCell.new(row:, reference: costs[:reference_currency]).call

        assert_equal [ "2026-09-30", yearly ], cost[:run_rate_at_end].then { [ it[:on], it[:total][:scenario][:converted] ] }, who
        assert_equal cost[:run_rate_at_end].slice(:on, :open_ended, :horizon_months, :total), row[:run_rate_at_end], who
        [ account, [ cost.to_json, costs.to_json, strip, cell ].map { it.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "") } ]
      end

      assert_equal [ "2894" ] * 2 + [ "+AUD 2.89k" ] * 2, seen[@holder].map { it[/\+AUD 2\.89k|2894/] }, "the holder sees the change on Today's"
      [ @editor, @viewer ].each do |account|
        seen[account].each do |output|
          %w[95311 95.3k 2894 2.89k 7583 7.58k].each { assert_not_includes output, it }
        end
      end
    end

    # Q2 sets no rate of its own, so its attrition is Q1's leavers alone: each
    # seat emptied in Q1's last 73 days stays empty into Q2, 0.1 / 365 × 73² / 2
    # = 266.45 / 365 FTE-days, priced as Q1 priced the seat for the caller.
    should "price a step's carried attrition as the caller sees the pay, never as the holder does for anyone else" do
      q2 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")[:scenario_id]
      call(Operations::TeamPlanning::SetRule, @holder, plan_id: @plan_id, scenario_id: @q1, rule: "attrition", value: { "yearly_rate" => "0.1" })
      call(Operations::TeamPlanning::SetRule, @holder, plan_id: @plan_id, scenario_id: @q1, rule: "time_to_hire", value: { "days" => "73" })
      call(Operations::TeamPlanning::SetRule, @holder, plan_id: @plan_id, scenario_id: q2, rule: "attrition", value: { "yearly_rate" => "0" })
      empty = Rational(26_645, 100 * 365) / 365
      derived = BigDecimal(Integer(AMOUNT) * empty, 20).to_s("F")[0, 5]

      carried = { @holder => Integer(AMOUNT), @editor => 100_000, @viewer => 100_000 }.to_h do |account, yearly|
        forecast = call(Operations::TeamPlanning::Forecast, account, plan_id: @plan_id, scenario_id: q2)
        attrition = forecast[:rows].sum { BigDecimal(it[:cost].fetch("AUD", "0")) } - 1000
        assert_in_delta(-yearly * empty, attrition, 1e-6, account == @holder ? "holder" : "non-holder")
        [ account, [ attrition, forecast ] ]
      end

      assert_includes carried[@holder].last.to_json, derived
      [ @editor, @viewer ].each do |account|
        assert_not_equal carried[@holder].first, carried[account].first
        cost = call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id: q2)
        [ cost, carried[account].last ].each { assert_not_includes it.to_json, derived }
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
    q1_amount = "57203"
    hold_pay(@q1, @ada, q1_amount, "full_time")
    moved = call(Operations::TeamPlanning::History, @holder, plan_id: @plan_id, scenario_id: @q1)[:entries].select { it[:facet] == "data:pay" }.last[:event_id]
    call(Operations::TeamPlanning::SetPlannedLevel, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
    needs = call(Operations::TeamPlanning::SplitNeeds, @editor, plan_id: @plan_id, scenario_id: @q1)
    pay = needs[:changes].find { it[:facet] == "data:pay" }

    assert_equal({ event_id: moved, subject_id: @ada.id, facet: "data:pay", needs: [] }, pay)
    assert_not_includes needs.to_json, q1_amount

    split = call(Operations::TeamPlanning::SplitScenario, @editor, plan_id: @plan_id, scenario_id: @q1, event_ids: [ moved ], name: "Agreed")

    assert_includes split[:moved_event_ids], moved
    assert_not_includes split.to_json, q1_amount
    agreed = call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: split[:agreed_id]).to_json
    assert_includes agreed, q1_amount
    assert_not_includes agreed, AMOUNT
    assert_includes call(Operations::TeamPlanning::ScenarioMap, @holder, plan_id: @plan_id, scenario_id: @plan_id).to_json, AMOUNT
    [ split[:agreed_id], @q1, @plan_id ].each { assert_no_pay_read(it, amounts: [ AMOUNT, q1_amount ]) }
    assert_not_includes @log.string, q1_amount
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

  context "a change's note" do
    setup do
      @pay_note = "Zephyr settled on 61873 a year"
      @level_note = "Zephyr earned the step, 61874 in band"
      call(Operations::TeamPlanning::NoteChange, @holder, plan_id: @plan_id, scenario_id: @q1, event_id: @event_id, note: @pay_note)
      call(Operations::TeamPlanning::SetPlannedLevel, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4")
      level = call(Operations::TeamPlanning::History, @holder, plan_id: @plan_id, scenario_id: @q1)[:entries]
              .find { it[:subject_id] == @ada.id && it[:action] == "set" && it[:facet] != "data:pay" }
      call(Operations::TeamPlanning::NoteChange, @holder, plan_id: @plan_id, scenario_id: @q1, event_id: level[:event_id], note: @level_note)
    end

    should "reach a holder on a pay change and on any other, and the rest on the other alone, in every read and on the Changes tab" do
      { "holder" => @holder, "editor" => @editor, "viewer" => @viewer }.each do |who, account|
        changes = changes_tab(account)

        assert_note_read(account, @level_note, who)
        assert_includes changes, @level_note, who
        if account == @holder
          assert_note_read(account, @pay_note, who)
          assert_includes changes, @pay_note
        else
          refute_note_read(account, @pay_note, who)
          assert_not_includes changes, @pay_note, who
          assert_no_pay_note_read(account, who)
        end
      end
    end

    should "give no sign of a note on a pay change to anyone without the right" do
      [ @editor, @viewer ].each do |account|
        history = call(Operations::TeamPlanning::History, account, plan_id: @plan_id, scenario_id: @q1)[:entries]
        pay = history.select { it[:facet] == "data:pay" }

        assert pay.any?
        assert pay.none? { it.key?(:note) || it[:action] == "note" }
        [ Operations::TeamPlanning::Status, Operations::TeamPlanning::Overrides ].each do |operation|
          rows = call(operation, account, plan_id: @plan_id, scenario_id: @q1).values_at(:statuses, :overrides).compact.flatten
          assert rows.select { it[:facet] == "data:pay" }.none? { it.key?(:note) }, operation.name
        end
      end
    end

    should "offer the note form on a pay change to an editor with the right alone" do
      assert_equal 2, changes_tab_html(@holder).css("[data-change-note-editor]").size
      assert_equal 1, changes_tab_html(@editor).css("[data-change-note-editor]").size
      assert_empty changes_tab_html(@viewer).css("[data-change-note-editor]")
    end

    should "hide a pay change's note from a member at once when their see-pay right is withdrawn" do
      call(Operations::TeamPlanning::GrantSeePay, @holder, plan_id: @plan_id, person_id: @editor.person_id)
      assert_note_read(@editor, @pay_note, "editor")
      assert_includes changes_tab(@editor), @pay_note

      call(Operations::TeamPlanning::WithdrawSeePay, @holder, plan_id: @plan_id, person_id: @editor.person_id)

      refute_note_read(@editor, @pay_note, "editor")
      assert_not_includes changes_tab(@editor), @pay_note
      assert_no_pay_note_read(@editor, "editor")
      assert_note_read(@editor, @level_note, "editor")
    end

    should "keep a pay change's note from the rest when it moves across a split" do
      split = call(Operations::TeamPlanning::SplitScenario, @holder, plan_id: @plan_id, scenario_id: @q1, event_ids: [ @event_id ], name: "Agreed")

      assert_not_includes split.to_json, @pay_note
      assert_note_read(@holder, @pay_note, "holder", split[:agreed_id])
      [ @editor, @viewer ].each { assert_no_pay_note_read(it, it == @editor ? "editor" : "viewer", split[:agreed_id]) }
    end

    # A budget amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)).
    should "keep a note on a budget-line change to holders, and offer its form to them alone" do
      line_note = "Zephyr's line goes to 61875"
      call(Operations::TeamPlanning::SetBudgetLine, @holder, plan_id: @plan_id, scenario_id: @q1, starts_on: "2026-01-01", ends_on: "2026-12-31",
                                                             origin: "new", amount: "61875", currency: "AUD", period: "year", head_count: "1")
      set = call(Operations::TeamPlanning::History, @holder, plan_id: @plan_id, scenario_id: @q1)[:entries].find { it[:facet] == "budget_line" }
      call(Operations::TeamPlanning::NoteChange, @holder, plan_id: @plan_id, scenario_id: @q1, event_id: set[:event_id], note: line_note)

      assert_note_read(@holder, line_note, "holder")
      assert_equal 3, changes_tab_html(@holder).css("[data-change-note-editor]").size
      assert_equal 1, changes_tab_html(@editor).css("[data-change-note-editor]").size
      { "editor" => @editor, "viewer" => @viewer }.each do |who, account|
        refute_note_read(account, line_note, who)
        assert_not_includes changes_tab(account), line_note, who
        history = call(Operations::TeamPlanning::History, account, plan_id: @plan_id, scenario_id: @q1)[:entries]
        assert history.select { it[:facet] == "budget_line" }.none? { it.key?(:note) || it[:action] == "note" }, who
      end
    end
  end

  # Status holds no budget line against today ([#446](https://github.com/espaliahq/espalia/issues/446)),
  # so a line whose amount alone changes upstream leaves what a member without
  # see-pay reads as it was.
  should "show a member without see-pay nothing that tells a budget line's amount changed upstream" do
    line = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 80_000, currency: "AUD",
                              period: "year", head_count: 1).id
    call(Operations::TeamPlanning::SetBudgetLine, @holder, plan_id: @plan_id, scenario_id: @q1, budget_line_id: line, starts_on: "2026-01-01",
                                                           ends_on: "2026-12-31", origin: "new", amount: "80000", currency: "AUD", period: "year",
                                                           head_count: "2")
    # After the base date, so the update-to-today preview reads rather than refuses.
    travel_to Time.utc(2026, 4, 1, 9)
    members = { "editor" => @editor, "viewer" => @viewer }
    before = members.transform_values { line_reads(it) }

    BudgetLine.find(line).update!(amount: 90_000)

    upstream = call(Operations::Tenants::BudgetLines, @holder, budget_line_id: line).to_json
    assert_includes upstream, "90000", "the line moved upstream, so the walk below has a change to miss"
    statuses = [ @holder, @editor, @viewer ].map do |account|
      call(Operations::TeamPlanning::Status, account, plan_id: @plan_id, scenario_id: @q1)[:statuses].select { it[:subject_id] == line }.pluck(:status)
    end
    assert_equal [ %w[plan_only] ] * 3, statuses, "a budget line is the plan's alone, for every member"
    assert_includes before["editor"]["team_planning_rebase_preview in Q1"], "\"scenarios\"", "the preview reads, so its conflicts are compared"
    members.each do |who, account|
      line_reads(account).each { |read, output| assert_equal before[who][read], output, "#{read} as #{who}" }
    end
  end

  # A budget line can't be pinned, so its override never reads parent_moved,
  # and inherits reads it without its money for a member without see-pay.
  should "show a member without see-pay nothing in what a budget line inherits when only its parent's amount moves" do
    line = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 80_000, currency: "AUD",
                              period: "year", head_count: 1).id
    figures = { budget_line_id: line, starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", currency: "AUD", period: "year", head_count: "2" }
    call(Operations::TeamPlanning::SetBudgetLine, @holder, plan_id: @plan_id, scenario_id: @q1, amount: "80000", **figures)
    q2 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, parent_id: @q1, relation: "instead", name: "Q1 lean")[:scenario_id]
    pin = assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::PinChange, @holder, plan_id: @plan_id, scenario_id: q2, subject_id: line, facet: "budget_line")
    end
    assert_match "can't be pinned", pin.message
    call(Operations::TeamPlanning::SetBudgetLine, @holder, plan_id: @plan_id, scenario_id: q2, amount: "80000", **figures, head_count: "3")
    pinned = lambda do |account|
      row = call(Operations::TeamPlanning::Overrides, account, plan_id: @plan_id, scenario_id: q2)[:overrides].find { it[:subject_id] == line }
      { pinned: row[:pinned], parent_moved: row[:parent_moved], end_state: row[:end_state], inherits: row[:inherits][:end_state] }
    end
    members = { "editor" => @editor, "viewer" => @viewer }
    before = members.transform_values { pinned.call(it) }
    assert_equal [ false, nil ], before["editor"].values_at(:pinned, :parent_moved)
    assert_equal 2, BigDecimal(before["editor"][:inherits]["head_count"].to_s), "Q2 inherits Q1's line"
    members.each_key { |who| assert_empty before[who].values_at(:end_state, :inherits).flat_map(&:keys) & %w[amount currency period], who }

    call(Operations::TeamPlanning::SetBudgetLine, @holder, plan_id: @plan_id, scenario_id: @q1, amount: "85000", **figures)

    members.each { |who, account| assert_equal before[who], pinned.call(account), who }
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

  should "offer an editor whose see-pay right is withdrawn no undo, redo or clear of the pay change they made" do
    call(Operations::TeamPlanning::GrantSeePay, @holder, plan_id: @plan_id, person_id: @editor.person_id)
    call(Operations::TeamPlanning::SetActualPay, @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                                                          amount: AMOUNT, currency: "AUD", period: "year", basis: "full_time")
    step = -> { call(Operations::TeamPlanning::UndoStep, @editor, plan_id: @plan_id, scenario_id: @q1) }
    pay_clearable = -> { call(Operations::TeamPlanning::Status, @editor, plan_id: @plan_id, scenario_id: @q1)[:statuses].find { it[:facet] == "data:pay" }[:clearable] }
    assert_equal "data:pay", step.call[:undo][:facet]
    assert pay_clearable.call

    call(Operations::TeamPlanning::WithdrawSeePay, @holder, plan_id: @plan_id, person_id: @editor.person_id)
    assert_equal({ undo: nil, redo: nil }, step.call.slice(:undo, :redo))
    assert_not pay_clearable.call

    call(Operations::TeamPlanning::GrantSeePay, @holder, plan_id: @plan_id, person_id: @editor.person_id)
    call(Operations::TeamPlanning::UndoChange, @editor, plan_id: @plan_id, scenario_id: @q1)
    call(Operations::TeamPlanning::WithdrawSeePay, @holder, plan_id: @plan_id, person_id: @editor.person_id)
    assert_equal({ undo: nil, redo: nil }, step.call.slice(:undo, :redo))
    assert_not_includes step.call.to_json, AMOUNT
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

    assert_equal "This scenario holds 1 change to pay or budget amounts you can't see. Removing it removes that too.", notice
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
      e5 = @e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
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
      { @in => "Platform", @out => "Field Sales" }.each { |person, cost_centre| people.change_cost_centre(person.id, cost_centre, provider: "espalia", effective_on: "2026-01-01") }

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

    # Q1 holds 121 of the year's 365 days. The line's 80,000 sits between the
    # held pay and the midpoint, so over shows which of the two judged it.
    should "fund a budget line from held pay for a holder, and from midpoints alone for everyone else" do
      line = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 80_000, currency: "AUD",
                                period: "year", cost_centre: "Platform").id
      position_id = call(Operations::TeamPlanning::SetPosition, @holder, plan_id: @plan_id, scenario_id: @q1, role_id: @e5.role_id,
                                                                         level_id: @e5.level_id, unit_id: @payments, fte: 1, basis: "new",
                                                                         cost_centre: "Platform")[:position_id]
      call(Operations::TeamPlanning::SetAssignment, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @in.id,
                                                             placements: [ { position_id:, allocation: 1 } ])
      share = Rational(121, 365)
      held = BigDecimal(Integer(SCOPED[:in]) * share, Operations::TeamPlanning::CostFigures::SIGNIFICANT_DIGITS).to_s("F")
      # A prefix, so a leak shows however it is rounded.
      derived = held[0, 5]

      funded = Integer(SCOPED[:in]) * share
      budget = call(Operations::TeamPlanning::Budget, @holder, plan_id: @plan_id, scenario_id: @q1)
      drawn = budget[:budget_lines].find { it[:budget_line_id] == line }
      assert_in_delta funded, BigDecimal(drawn[:funded][:native]["AUD"]), 1e-9
      assert_in_delta 80_000 * share - funded, BigDecimal(drawn[:remaining][:amount]), 1e-9
      assert_equal({ money: [], heads: nil, mismatched_currencies: [] }, drawn[:over])
      assert_equal held, drawn[:funded][:native]["AUD"]

      # A budget amount is pay too ([#367](https://github.com/espaliahq/espalia/issues/367)).
      [ @editor, @viewer ].each do |account|
        budget = call(Operations::TeamPlanning::Budget, account, plan_id: @plan_id, scenario_id: @q1)
        drawn = budget[:budget_lines].find { it[:budget_line_id] == line }
        assert_equal [ nil, nil, nil ], [ drawn[:funded][:native], drawn[:remaining][:amount], drawn[:over][:money] ]
        figures = budget.to_json.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "")
        [ derived, "80000", (80_000 * share).to_i.to_s[0, 4] ].each { assert_not_includes figures, it }
      end
    end

    should "show each member the Budget tab's totals exactly as team_planning_budget gives them, with no figure from held pay without the right" do
      BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 500_000, currency: "AUD", period: "year", cost_centre: "Platform")
      position_id = call(Operations::TeamPlanning::SetPosition, @holder, plan_id: @plan_id, scenario_id: @q1, role_id: @e5.role_id,
                                                                         level_id: @e5.level_id, unit_id: @payments, fte: 1, basis: "new",
                                                                         cost_centre: "Platform")[:position_id]
      call(Operations::TeamPlanning::SetAssignment, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @in.id,
                                                             placements: [ { position_id:, allocation: 1 } ])
      budget = call(Operations::TeamPlanning::Budget, @holder, plan_id: @plan_id, scenario_id: @q1)
      held = Views::Plans::CostMarks::Format.amount(budget[:total][:funded][:native]["AUD"], "AUD")
      html = budget_tab(@holder)
      tiles = html.css("[data-budget-total]").to_h { [ it["data-budget-total"].to_sym, it.at_css("dd").text ] }
      assert_equal(budget[:total].slice(:approved, :funded, :remaining, :unfunded).transform_values { Views::Plans::CostMarks::Format.sum(it, "AUD") }, tiles)
      assert_includes html.text, held

      [ @editor, @viewer ].each do |account|
        html = budget_tab(account)
        tiles = html.css("[data-budget-total]").to_h { [ it["data-budget-total"].to_sym, it.at_css("dd").text ] }

        assert_equal({ approved: "No head count", funded: "1 position, 1 FTE", remaining: "No head count", unfunded: "0 positions, 0 FTE" }, tiles)
        assert_includes html.text, "Budget amounts show only to members who may see pay."
        [ held, "500,000", "AUD", "No amount", *SCOPED.values ].each { assert_not_includes html.to_html, it }
      end
    end

    should "give each member the timeline's budget figures as team_planning_budget gives them, with no budget money without the right" do
      BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 500_000, currency: "AUD", period: "year", cost_centre: "Platform")
      BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 654_321, currency: "AUD", period: "year", cost_centre: "Field Sales")
      position_id = call(Operations::TeamPlanning::SetPosition, @holder, plan_id: @plan_id, scenario_id: @q1, role_id: @e5.role_id,
                                                                         level_id: @e5.level_id, unit_id: @payments, fte: 1, basis: "new",
                                                                         cost_centre: "Platform")[:position_id]
      call(Operations::TeamPlanning::SetAssignment, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @in.id,
                                                             placements: [ { position_id:, allocation: 1 } ])
      held = call(Operations::TeamPlanning::Budget, @holder, plan_id: @plan_id, scenario_id: @q1)[:total][:funded][:native]["AUD"]

      [ @holder, @editor, @viewer ].each do |account|
        who = account == @holder ? "holder" : "non-holder"
        budget = call(Operations::TeamPlanning::Budget, account, plan_id: @plan_id, scenario_id: @q1)[:total]
        figures = call(Operations::TeamPlanning::TimelineFigures, account, plan_id: @plan_id, scenario_id: @q1)
        assert_equal budget.slice(:approved, :funded, :unfunded, :over), figures[:steps].last[:budget], who
        if account == @holder
          assert_equal held, figures[:steps].last[:budget][:funded][:native]["AUD"]
        else
          text = figures.to_json.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "")
          [ held[0, 5], "500000", "654321", *SCOPED.values ].each { assert_not_includes text, it, who }
        end
      end
    end

    # A plan's scope decides which lines it holds, not the see-pay right
    # ([#378](https://github.com/espaliahq/espalia/issues/378)).
    should "show no member a line outside the plan's cost centres, nor a total that counts it, holder or not" do
      held = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 500_000, currency: "AUD", period: "year", cost_centre: "Platform")
      away = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 654_321, currency: "AUD", period: "year", cost_centre: "Field Sales")

      [ @holder, @editor, @viewer ].each do |account|
        who = account == @holder ? "holder" : "non-holder"
        budget = call(Operations::TeamPlanning::Budget, account, plan_id: @plan_id, scenario_id: @q1)
        assert_equal [ held.id ], budget[:budget_lines].map { it[:budget_line_id] }, who
        assert_equal [ "Platform" ], budget[:cost_centres].filter_map { it[:cost_centre] }, who
        if account == @holder
          assert_in_delta held.amount * Rational(121, 365), BigDecimal(budget[:total][:approved][:native]["AUD"]), 1e-9, who
        else
          assert_nil budget[:total][:approved][:native], who
        end
        reads = [ budget, call(Operations::TeamPlanning::BudgetLines, account, plan_id: @plan_id, scenario_id: @q1),
                  call(Operations::TeamPlanning::Funding, account, plan_id: @plan_id, scenario_id: @q1), budget_tab(account).to_html ].to_json
        assert_not_includes reads, away.id, who
        figures = reads.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "")
        [ "Field Sales", "654", "654,321" ].each { assert_not_includes figures, it, who }
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

    # Archived on 1 February 2026, then the band, the line and the rules all
    # move. The frozen copy prices midpoints at 100,000; held pay is never in it.
    context "once archived" do
      setup do
        @line = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 80_000, currency: "AUD",
                                   period: "year", cost_centre: "Platform").id
        position_id = call(Operations::TeamPlanning::SetPosition, @holder, plan_id: @plan_id, scenario_id: @q1, role_id: @e5.role_id,
                                                                           level_id: @e5.level_id, unit_id: @payments, fte: 1, basis: "new",
                                                                           cost_centre: "Platform")[:position_id]
        call(Operations::TeamPlanning::SetAssignment, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: @in.id,
                                                               placements: [ { position_id:, allocation: 1 } ])
        call(Operations::TeamPlanning::SetRule, @holder, plan_id: @plan_id, scenario_id: @plan_id, rule: "attrition", value: { "yearly_rate" => "0.1" })
        call(Operations::TeamPlanning::SetRule, @holder, plan_id: @plan_id, scenario_id: @plan_id, rule: "time_to_hire", value: { "days" => "73" })
        call(Operations::TeamPlanning::ArchivePlan, @holder, plan_id: @plan_id)

        PayBand.find_by!(level_id: @e5.level_id).update!(midpoint: 130_000, maximum: 260_000)
        BudgetLine.find(@line).update!(amount: 10_000)
        PlanningRuleDefault.create!(rule: "on_cost", value: { "model" => "flat", "params" => { "percent" => "40" } })
        @share = Rational(121, 365)
        @held = BigDecimal(Integer(SCOPED[:in]) * @share, Operations::TeamPlanning::CostFigures::SIGNIFICANT_DIGITS).to_s("F")
      end

      should "price a holder from held pay and everyone else from the archive day's midpoints, in cost, scenario costs, budget, funding and forecast" do
        holder = frozen_reads(@holder)
        assert_equal "2026-02-01", holder[:cost][:priced_on]
        assert_equal @held, holder[:budget][:budget_lines].find { it[:budget_line_id] == @line }[:funded][:native]["AUD"]
        assert_equal [ "2026-02-01", 1 ], holder[:funding].values_at(:priced_on, :funded).then { [ it[0], it[1][:positions] ] }

        [ @editor, @viewer ].each do |account|
          reads = frozen_reads(account)
          assert_nil reads[:budget][:budget_lines].find { it[:budget_line_id] == @line }[:funded][:native], "a budget amount is pay"
          seat = call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments)[:seats][:scenario].find { it[:seat_id] == @in.id }
          assert_equal "band_midpoint", seat[:pay_source]
          assert_in_delta 100_000 * @share, BigDecimal(seat[:base]), 1e-9, "the archive day's midpoint, not today's 130,000"
          assert_not_equal holder[:forecast][:rows], reads[:forecast][:rows], "attrition is priced as each caller sees the seat"
          reads.each do |name, payload|
            [ *SCOPED.values, @held[0, 5] ].each { assert_not_includes payload.to_json, it, "#{name} as a non-holder" }
          end
        end
      end

      should "show a viewer and an editor without the see-pay right no pay from any read" do
        [ @q1, @plan_id ].each { assert_no_pay_read(it, amounts: SCOPED.values) }
      end

      should "keep held pay and band figures out of the copy as stored" do
        stored = ActiveRecord::Base.connection.select_values(
          "SELECT encode(data, 'escape') FROM event_store_events WHERE event_type = 'TeamPlanning::Events::PlanPricesFrozen'"
        )

        assert_equal 1, stored.size
        [ *SCOPED.values, "pay_bands", "midpoint", "Platform" ].each { assert_not_includes stored.first, it }
      end

      should "leave a forgotten person's pay unknown to a holder and their seat at the midpoint for a viewer" do
        PlanKeyStore.new.destroy_person(@in.id)

        holder = call(Operations::TeamPlanning::Cost, @holder, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments)
        assert_includes holder[:unpriced].map { [ it[:seat_id], it[:reason] ] }, [ @in.id, "pay_unknown" ]
        viewer = call(Operations::TeamPlanning::Cost, @viewer, plan_id: @plan_id, scenario_id: @q1, unit_id: @payments)
        seat = viewer[:seats][:scenario].find { it[:seat_id] == @in.id }
        assert_equal "band_midpoint", seat[:pay_source]
        assert_in_delta 100_000 * @share, BigDecimal(seat[:base]), 1e-9
        [ holder, viewer, *frozen_reads(@holder).values, *frozen_reads(@viewer).values ].each do |payload|
          assert_not_includes payload.to_json, SCOPED[:in]
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

  def note_reads(account, scenario_id = @q1)
    [ Operations::TeamPlanning::Status, Operations::TeamPlanning::Overrides, Operations::TeamPlanning::History ]
      .to_h { [ it.name.demodulize, call(it, account, plan_id: @plan_id, scenario_id:).to_json ] }
  end

  def assert_note_read(account, note, who, scenario_id = @q1)
    note_reads(account, scenario_id).each { |read, output| assert_includes output, note, "#{read} as #{who}" }
  end

  def refute_note_read(account, note, who, scenario_id = @q1)
    note_reads(account, scenario_id).each { |read, output| assert_not_includes output, note, "#{read} as #{who}" }
  end

  def assert_no_pay_note_read(account, who, scenario_id = @q1)
    [ scenario_id, @plan_id ].each do |id|
      READS.call.each do |operation|
        output = begin
          call(operation, account, **params_for(operation, scenario_id: id)).to_json
        rescue Operations::Base::ParameterError => e
          e.message
        end
        [ @pay_note, "Zephyr settled" ].each { assert_not_includes output, it, "#{Operations::Registry.tool_name_for(operation)} as #{who}" }
      end
    end
  end

  def changes_tab_html(account, scenario_id = @q1)
    plan = call(Operations::TeamPlanning::Plan, account, plan_id: @plan_id)
    scenarios = call(Operations::TeamPlanning::Scenarios, account, plan_id: @plan_id)[:scenarios]
    reads = { drift: Operations::TeamPlanning::Drift, status: Operations::TeamPlanning::Status, attention: Operations::TeamPlanning::Attention }
            .to_h { |key, operation| [ key, call(operation, account, **params_for(operation, scenario_id:)) ] }
    record = TeamPlanningPlan.find(@plan_id)
    policy = PlanPolicy.new(context_for(account), record)
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::ChangesTab.new(plan:, scenarios:, **reads, can_edit: policy.update?,
                                                                                        see_pay: policy.see_pay?)))
  end

  def changes_tab(account) = changes_tab_html(account).to_html

  def line_reads(account)
    reads = { "Q1" => @q1, "Today" => @plan_id }.flat_map do |name, scenario_id|
      READS.call.map do |operation|
        output = begin
          call(operation, account, **params_for(operation, scenario_id:)).to_json
        rescue Operations::Base::ParameterError => e
          e.message
        end
        [ "#{Operations::Registry.tool_name_for(operation)} in #{name}", output ]
      end
    end
    reads.to_h.merge("Changes tab" => changes_tab(account))
  end

  def frozen_reads(account)
    { cost: call(Operations::TeamPlanning::Cost, account, plan_id: @plan_id, scenario_id: @q1),
      scenario_costs: call(Operations::TeamPlanning::ScenarioCosts, account, plan_id: @plan_id),
      budget: call(Operations::TeamPlanning::Budget, account, plan_id: @plan_id, scenario_id: @q1),
      funding: call(Operations::TeamPlanning::Funding, account, plan_id: @plan_id, scenario_id: @q1),
      forecast: call(Operations::TeamPlanning::Forecast, account, plan_id: @plan_id, scenario_id: @q1) }
  end


  def budget_tab(account)
    reads = { budget: Operations::TeamPlanning::Budget, funding: Operations::TeamPlanning::Funding, map: Operations::TeamPlanning::ScenarioMap,
              lines: Operations::TeamPlanning::BudgetLines }.transform_values { call(it, account, plan_id: @plan_id, scenario_id: @q1) }
    plan = call(Operations::TeamPlanning::Plan, account, plan_id: @plan_id)
    scenarios = call(Operations::TeamPlanning::Scenarios, account, plan_id: @plan_id)[:scenarios]
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::BudgetTab.new(plan:, scenarios:, **reads)))
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
