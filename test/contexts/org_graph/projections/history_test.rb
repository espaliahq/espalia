# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class OrgGraph::Projections::HistoryTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  START = Time.zone.parse("2026-02-01 09:00")

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @departments, @squads = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @platform = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to START
    as_tenant do
      @ada, @grace = create_list(:person, 2, tenant: @tenant)
      @structure.define_taxonomy([ { level_id: @departments, name: "Department" }, { level_id: @squads, name: "Squad" } ],
        effective_on: "2026-01-01")
      @structure.create_unit(@engineering, "Engineering", level_id: @departments, effective_on: "2026-01-01")
      @structure.create_unit(@payments, "Payments", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
      @structure.create_unit(@platform, "Platform", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def record(person, **facts)
    as_tenant do
      @handler.record_person(person.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", **facts)
    end
  end

  def later(days = 1) = travel(days.days)

  # The periods the Org Graph believed at an instant, as [from, to, value].
  def timeline(subject_id, fact, key: "", known_at: Time.current)
    as_tenant do
      OrgFactPeriod.known_at(known_at).where(subject_id:, fact:, key:).order(:effective_from)
                   .map { |row| [ row.effective_from.iso8601, row.effective_to&.iso8601, row.value ] }
    end
  end

  def value_on(subject_id, fact, on, key: "", known_at: Time.current)
    as_tenant do
      OrgFactPeriod.known_at(known_at).in_effect_on(Date.iso8601(on)).where(subject_id:, fact:, key:).sole.value
    end
  end

  def statuses(person, known_at: Time.current)
    timeline(person.id, "employment_status", known_at:).map { |from, to, value| [ from, to, value["employment_status"] ] }
  end

  context "person facts" do
    should "hold each fact with its provider, its period and when it was learned" do
      record(@ada, title: "Engineer", level: "L3", manager_id: @grace.id, cost_centre: "R&D", site: "Sydney",
                   fte: 1.0, employment_type: "Full-time")
      later
      as_tenant do
        @structure.set_fact_provider("title", "hibob", effective_on: "2026-03-01")
        @ada.update!(external_id: "ada-1", hris_source: "hibob")
        @handler.apply_facts(@ada.id, provider: "hibob", effective_on: "2026-03-01", title: "Senior Engineer")
      end

      assert_equal [ [ "2026-02-01", "2026-03-01", { "title" => "Engineer" } ],
                     [ "2026-03-01", nil, { "title" => "Senior Engineer" } ] ], timeline(@ada.id, "title")
      assert_equal({ "site" => "Sydney", "country" => nil }, value_on(@ada.id, "site", "2026-02-01"))
      assert_equal({ "fte" => 1.0, "employment_type" => "Full-time" }, value_on(@ada.id, "employment", "2026-02-01"))
      assert_equal({ "manager_id" => @grace.id }, value_on(@ada.id, "manager", "2026-02-01"))

      senior = as_tenant { OrgFactPeriod.current.find_by(subject_id: @ada.id, fact: "title", effective_from: "2026-03-01") }
      assert_equal [ "person", "hibob", START + 1.day ], [ senior.subject_type, senior.provider, senior.learned_at ]
      first = as_tenant { OrgFactPeriod.current.find_by(subject_id: @ada.id, fact: "title", effective_from: "2026-02-01") }
      assert_equal [ "espalia", START + 1.day ], [ first.provider, first.learned_at ]
    end

    should "add rows for a backdated correction and keep what was known before it" do
      record(@ada, title: "Engineer")
      later
      learned_senior = Time.current
      as_tenant { @handler.apply_facts(@ada.id, **ESPALIA, effective_on: "2026-03-01", title: "Senior Engineer") }
      later
      as_tenant { @handler.apply_facts(@ada.id, **ESPALIA, effective_on: "2026-02-15", title: "Lead Engineer") }

      assert_equal [ [ "2026-02-01", "2026-02-15", { "title" => "Engineer" } ],
                     [ "2026-02-15", "2026-03-01", { "title" => "Lead Engineer" } ],
                     [ "2026-03-01", nil, { "title" => "Senior Engineer" } ] ], timeline(@ada.id, "title")
      assert_equal [ [ "2026-02-01", "2026-03-01", { "title" => "Engineer" } ],
                     [ "2026-03-01", nil, { "title" => "Senior Engineer" } ] ],
        timeline(@ada.id, "title", known_at: learned_senior)
      assert_equal({ "title" => "Engineer" }, value_on(@ada.id, "title", "2026-02-20", known_at: learned_senior))
      assert_equal({ "title" => "Lead Engineer" }, value_on(@ada.id, "title", "2026-02-20"))
      assert_equal [ [ "2026-02-01", nil, { "title" => "Engineer" } ] ], timeline(@ada.id, "title", known_at: START)

      superseded = as_tenant { OrgFactPeriod.where(subject_id: @ada.id, fact: "title").where.not(superseded_at: nil) }
      assert_equal [ START + 1.day, START + 2.days ], superseded.map(&:superseded_at).sort
    end

    should "write each event once, however often it is delivered" do
      record(@ada, title: "Engineer")
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::PersonRecorded).last

      assert_no_difference(-> { as_tenant { OrgFactPeriod.count } }) { OrgGraph::Projections::History.new.call(event) }
    end

    should "write an event's rows together or not at all" do
      record(@ada, title: "Engineer", level: "L3")
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::PersonRecorded).last
      as_tenant { OrgFactPeriod.delete_all }
      insert, calls = OrgFactPeriod.method(:insert_all!), 0
      failing_second = lambda do |*args|
        calls += 1
        raise ActiveRecord::StatementInvalid, "lost connection" if calls == 2

        insert.call(*args)
      end

      OrgFactPeriod.stub(:insert_all!, failing_second) do
        assert_raises(ActiveRecord::StatementInvalid) { OrgGraph::Projections::History.new.call(event) }
      end
      as_tenant { assert_equal 0, OrgFactPeriod.count }

      OrgGraph::Projections::History.new.call(event)
      assert_equal({ "level" => "L3" }, value_on(@ada.id, "level", "2026-02-01"))
    end

    should "keep no event's state on the subscriber that every publishing thread shares" do
      record(@ada, title: "Engineer")
      projection = OrgGraph::Projections::History.new
      as_tenant { OrgFactPeriod.delete_all }
      projection.call(Rails.configuration.event_store.read.of_type(OrgGraph::Events::PersonRecorded).last)

      assert_equal [ [ "2026-02-01", nil, { "title" => "Engineer" } ] ], timeline(@ada.id, "title")
      assert_empty projection.instance_variables
    end
  end

  context "employment" do
    should "begin on the start date the person was recorded with" do
      record(@ada, started_on: "2025-06-01")

      assert_equal [ [ "2025-06-01", nil, "employed" ] ], statuses(@ada)
    end

    should "begin a pending hire's employment on the day they join, and move it with the start date" do
      as_tenant do
        @handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "pending",
                                                   started_on: "2026-03-01")
        @handler.join(@ada.id, **ESPALIA, effective_on: "2026-03-01")
      end
      assert_equal [ [ "2026-02-01", "2026-03-01", "pending" ], [ "2026-03-01", nil, "employed" ] ], statuses(@ada)

      later
      as_tenant do
        @handler.sync_person(@ada.id, **ESPALIA, effective_on: "2026-03-05", employment_status: "employed",
                                                 started_on: "2026-01-20")
      end
      assert_equal [ [ "2026-01-20", nil, "employed" ] ], statuses(@ada)
    end

    should "end on the leaving date, take a corrected date, and restore no membership on return" do
      record(@ada)
      as_tenant do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
        @handler.leave(@ada.id, **ESPALIA, effective_on: "2026-04-30")
        @handler.sync_person(@ada.id, **ESPALIA, effective_on: "2026-05-02", employment_status: "left",
                                                 left_on: "2026-04-15")
        @handler.return_to_work(@ada.id, **ESPALIA, effective_on: "2026-09-01")
      end

      assert_equal [ [ "2026-02-01", "2026-04-16", "employed" ], [ "2026-04-16", "2026-09-01", "left" ],
                     [ "2026-09-01", nil, "employed" ] ], statuses(@ada)
      assert_equal [ [ "2026-02-01", "2026-05-01", { "allocation" => 1.0, "role" => nil } ], [ "2026-05-01", nil, nil ] ],
        timeline(@ada.id, "membership", key: @payments)
    end

    should "leave a returner's employment on their return when the start date held is an earlier spell's" do
      record(@ada, started_on: "2025-06-01")
      as_tenant do
        @handler.leave(@ada.id, **ESPALIA, effective_on: "2026-04-30")
        @handler.sync_person(@ada.id, **ESPALIA, effective_on: "2026-09-01", employment_status: "employed",
                                                 started_on: "2025-05-01")
      end

      assert_equal [ [ "2025-06-01", "2026-05-01", "employed" ], [ "2026-05-01", "2026-09-01", "left" ],
                     [ "2026-09-01", nil, "employed" ] ], statuses(@ada)
    end

    should "end a pending hire who drops out on a date before they were recorded" do
      as_tenant do
        @handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "pending")
        @handler.leave(@ada.id, **ESPALIA, effective_on: "2026-01-15")
      end

      assert_equal [ [ "2026-01-16", nil, "left" ] ], statuses(@ada)
    end

    should "end a returner's new spell when their second leaving is dated before the return" do
      record(@ada, started_on: "2025-06-01")
      as_tenant do
        @handler.leave(@ada.id, **ESPALIA, effective_on: "2026-04-30")
        @handler.return_to_work(@ada.id, **ESPALIA, effective_on: "2026-09-01")
        @handler.leave(@ada.id, **ESPALIA, effective_on: "2026-08-15")
      end

      assert_equal [ [ "2025-06-01", "2026-05-01", "employed" ], [ "2026-05-01", nil, "left" ] ], statuses(@ada)
    end
  end

  context "memberships" do
    setup { record(@ada) }

    should "leave one unit and join the other on the date of a move, keeping the terms" do
      as_tenant do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 0.5, role: "Lead")
        @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-03-01")
      end

      assert_equal [ [ "2026-02-01", "2026-03-01", { "allocation" => 0.5, "role" => "Lead" } ], [ "2026-03-01", nil, nil ] ],
        timeline(@ada.id, "membership", key: @payments)
      assert_equal [ [ "2026-03-01", nil, { "allocation" => 0.5, "role" => "Lead" } ] ],
        timeline(@ada.id, "membership", key: @platform)
    end

    should "split a membership's periods for a backdated change of terms" do
      as_tenant do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
        @handler.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-05-31")
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-07-01", allocation: 0.5)
      end

      assert_equal [ [ "2026-02-01", "2026-06-01", { "allocation" => 1.0, "role" => nil } ],
                     [ "2026-06-01", "2026-07-01", nil ],
                     [ "2026-07-01", nil, { "allocation" => 0.5, "role" => nil } ] ],
        timeline(@ada.id, "membership", key: @payments)
    end

    should "withdraw a membership changed back on its own date, as a change learned at the change-back" do
      as_tenant { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0) }
      learned_set = Time.current
      later
      as_tenant { OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first) }

      assert_empty timeline(@ada.id, "membership", key: @payments)
      assert_equal [ [ "2026-02-01", nil, { "allocation" => 1.0, "role" => nil } ] ],
        timeline(@ada.id, "membership", key: @payments, known_at: learned_set)
    end

    should "keep a change dated later than the change it changes back" do
      as_tenant do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM)
                                   .change_back(OrgUnitActivity.for_unit(@payments).first, effective_on: "2026-03-01")
      end

      assert_equal [ [ "2026-02-01", "2026-03-02", { "allocation" => 1.0, "role" => nil } ], [ "2026-03-02", nil, nil ] ],
        timeline(@ada.id, "membership", key: @payments)
    end
  end

  context "structure" do
    should "hold a unit's name, parent, level and retirement, and the succession that replaced it" do
      billing, succession = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      as_tenant do
        @structure.rename_unit(@payments, "Payments Core", effective_on: "2026-02-01")
        @structure.create_unit(billing, "Billing", level_id: @squads, parent_id: @engineering, effective_on: "2026-03-01")
        @structure.record_succession(succession, predecessor_ids: [ @payments ], successor_ids: [ billing ],
                                                 effective_on: "2026-03-31", retire_predecessors: true)
      end

      assert_equal [ [ "2026-01-01", "2026-02-01", { "name" => "Payments" } ],
                     [ "2026-02-01", nil, { "name" => "Payments Core" } ] ], timeline(@payments, "name")
      assert_equal({ "parent_id" => @engineering }, value_on(@payments, "parent", "2026-02-01"))
      assert_equal({ "level_id" => @squads }, value_on(@payments, "level", "2026-02-01"))
      assert_equal [ [ "2026-01-01", "2026-04-01", { "status" => "live" } ],
                     [ "2026-04-01", nil, { "status" => "retired", "succession_id" => succession, "successor_ids" => [ billing ] } ] ],
        timeline(@payments, "status")
      assert_equal [ [ "2026-03-31", nil, { "predecessor_ids" => [ @payments ], "successor_ids" => [ billing ] } ] ],
        timeline(succession, "succession")
    end

    should "move a unit beneath another parent from the date it moved" do
      squad = SecureRandom.uuid_v7
      as_tenant do
        @structure.create_unit(squad, "Ledger", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
        other = SecureRandom.uuid_v7
        @structure.create_unit(other, "Finance", level_id: @departments, effective_on: "2026-01-01")
        @structure.move_unit(squad, other, effective_on: "2026-02-15")
        @other = other
      end

      assert_equal [ [ "2026-01-01", "2026-02-15", { "parent_id" => @engineering } ],
                     [ "2026-02-15", nil, { "parent_id" => @other } ] ], timeline(squad, "parent")
    end

    should "hold each owner of a unit from the day they were added to their last day" do
      as_tenant do
        @structure.add_unit_owner(@payments, @ada.id, effective_on: "2026-02-01")
        @structure.add_unit_owner(@payments, @grace.id, effective_on: "2026-02-01")
        @structure.remove_unit_owner(@payments, @ada.id, effective_on: "2026-03-31")
      end

      assert_equal [ [ "2026-02-01", "2026-04-01", { "owner" => true } ], [ "2026-04-01", nil, nil ] ],
        timeline(@payments, "owner", key: @ada.id)
      assert_equal [ [ "2026-02-01", nil, { "owner" => true } ] ], timeline(@payments, "owner", key: @grace.id)
    end
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state" do
      record(@ada, title: "Engineer", started_on: "2025-06-01")
      record(@grace)
      later
      as_tenant do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
        @handler.apply_facts(@ada.id, **ESPALIA, effective_on: "2026-03-01", title: "Senior Engineer")
        @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-03-01")
      end
      later
      as_tenant do
        @handler.apply_facts(@ada.id, **ESPALIA, effective_on: "2026-02-15", title: "Lead Engineer")
        @handler.set_membership(@grace.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first)
        @handler.leave(@grace.id, **ESPALIA, effective_on: "2026-04-30")
        @structure.rename_unit(@platform, "Platform Core", effective_on: "2026-01-15")
        @structure.add_unit_owner(@platform, @ada.id, effective_on: "2026-02-01")
      end

      before = snapshot_read_models(OrgGraph::Projections::History, @tenant)
      assert_operator before[:fact_periods].count { it["superseded_at"] }, :>, 0

      OrgGraph::Projections::History.reset!(tenant: @tenant)
      as_tenant { assert_equal 0, OrgFactPeriod.count }
      Projections::Replayer.replay(projection_class: OrgGraph::Projections::History, tenant: @tenant)

      assert_equal before, snapshot_read_models(OrgGraph::Projections::History, @tenant)
    end
  end
end
