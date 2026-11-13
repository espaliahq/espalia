# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class OrgGraph::Projections::FactAgesTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  HIBOB = { provider: "hibob", effective_on: "2026-02-01" }.freeze
  START = Time.zone.parse("2026-02-01 09:00")

  setup do
    @tenant = create(:tenant, org_graph_config: { staleness_days: 30 })
    @handler = OrgGraph::CommandHandler.new
    level = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7
    @platform = SecureRandom.uuid_v7

    travel_to START
    as_tenant do
      @ada, @grace, @lead = create_list(:person, 3, tenant: @tenant)
      structure = OrgGraph::StructureCommandHandler.new
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: level, effective_on: "2026-01-01")
      [ @ada, @grace, @lead ].each { |person| @handler.record_person(person.id, **HIBOB, employment_status: "employed", title: "Engineer") }

      @handler.set_membership(@ada.id, @payments, **ESPALIA, set_by_id: @lead.id)
      @handler.set_membership(@grace.id, @payments, **HIBOB)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def age(person, fact, unit_id = nil)
    as_tenant { OrgFactAge.find_by(person: person, fact: fact, unit_id: unit_id) }
  end

  def confirm(person, fact, unit_id: nil)
    as_tenant do
      @handler.confirm_fact(person.id, fact, unit_id: unit_id, confirmed_by_id: @lead.id, effective_on: Date.current)
    end
  end

  def stale(now: Time.current)
    as_tenant { OrgFactAge.stale(@tenant, now: now).map { |row| [ row.person_id, row.fact, row.unit_id ] } }
  end

  should "keep an age only for the facts Espalia holds" do
    ada = age(@ada, "membership", @payments)

    assert_equal [ START, START, @lead.id, nil ], [ ada.changed_at, ada.checked_at, ada.checked_by_id, ada.confirmed_at ]
    assert_nil age(@grace, "membership", @payments)
    assert_nil age(@ada, "title")
  end

  should "follow a person fact as it moves to Espalia, to another provider, and is cleared" do
    as_tenant { @handler.change_title(@ada.id, "Lead", **ESPALIA) }
    assert_equal START, age(@ada, "title").changed_at

    as_tenant { @handler.change_title(@ada.id, "Lead", **HIBOB) }
    assert_nil age(@ada, "title")

    as_tenant do
      @handler.change_title(@ada.id, "Lead", **ESPALIA)
      @handler.change_title(@ada.id, nil, **ESPALIA)
    end
    assert_nil age(@ada, "title")
  end

  should "age a fact from a confirmation, and start again from a change" do
    travel_to START + 20.days
    confirm(@ada, "membership", unit_id: @payments)
    confirmed = age(@ada, "membership", @payments)
    assert_equal [ START, START + 20.days, START + 20.days, @lead.id ],
      [ confirmed.changed_at, confirmed.confirmed_at, confirmed.checked_at, confirmed.checked_by_id ]

    travel_to START + 25.days
    as_tenant { @handler.set_membership(@ada.id, @payments, allocation: 0.5, **ESPALIA) }
    changed = age(@ada, "membership", @payments)
    assert_equal [ START + 25.days, nil, START + 25.days ], [ changed.changed_at, changed.confirmed_at, changed.checked_at ]
  end

  should "age each fact a person is recorded with by Espalia, and none left blank" do
    newcomer = as_tenant { create(:person, tenant: @tenant) }
    as_tenant { @handler.record_person(newcomer.id, **ESPALIA, employment_status: "employed", title: "Analyst", site: "Hobart") }

    assert_equal %w[site title], as_tenant { OrgFactAge.where(person: newcomer).order(:fact).pluck(:fact) }
  end

  should "keep a pair's unchanged half at its age" do
    as_tenant { @handler.change_site(@ada.id, site: "Sydney", country: "Australia", **ESPALIA) }
    travel_to START + 5.days
    confirm(@ada, "country")

    travel_to START + 9.days
    as_tenant { @handler.change_site(@ada.id, site: "Hobart", country: "Australia", **ESPALIA) }

    assert_equal [ START, START + 5.days ], age(@ada, "country").slice(:changed_at, :confirmed_at).values
    assert_equal [ START + 9.days, nil ], age(@ada, "site").slice(:changed_at, :confirmed_at).values
  end

  should "credit a membership to whoever set it, and a person fact to nobody the event names" do
    as_tenant { @handler.change_title(@ada.id, "Lead", **ESPALIA) }

    assert_equal @lead.id, age(@ada, "membership", @payments).checked_by_id
    assert_nil age(@ada, "title").checked_by_id
  end

  should "age only the person facts it lists, which match the ones a confirmation can name" do
    assert_equal OrgGraph::PersonAggregate.confirmable_facts - [ "membership" ],
      OrgGraph::Projections::FactAges::PERSON_FACTS.map(&:to_s)
  end

  should "drop a membership's age when it ends" do
    as_tenant { @handler.end_membership(@ada.id, @payments, **ESPALIA) }

    assert_nil age(@ada, "membership", @payments)
  end

  context ".stale" do
    should "list the facts past the tenant's threshold, oldest first" do
      as_tenant { @handler.set_membership(@ada.id, @platform, **ESPALIA) }
      travel_to START + 10.days
      as_tenant { @handler.change_manager(@grace.id, @lead.id, **ESPALIA) }

      assert_empty stale(now: START + 30.days)
      assert_equal [ [ @ada.id, "membership", @payments ], [ @ada.id, "membership", @platform ] ].sort,
        stale(now: START + 31.days).sort
      assert_equal [ @ada.id, @ada.id, @grace.id ], stale(now: START + 41.days).map(&:first)
    end

    should "clear a fact once it is confirmed" do
      travel_to START + 31.days
      assert_equal [ [ @ada.id, "membership", @payments ] ], stale

      confirm(@ada, "membership", unit_id: @payments)
      assert_empty stale
    end

    should "age a backdated fact from when it was learned, not when it took effect" do
      travel_to START + 20.days
      as_tenant { @handler.set_membership(@grace.id, @platform, provider: "espalia", effective_on: "2025-01-01") }

      assert_equal [ [ @ada.id, "membership", @payments ] ], stale(now: START + 31.days)
    end

    should "never list a leaver's facts, and list them again when they return" do
      travel_to START + 31.days
      as_tenant { @handler.leave(@ada.id, **HIBOB) }
      assert_empty stale

      as_tenant { @handler.return_to_work(@ada.id, **HIBOB) }
      assert_equal [ [ @ada.id, "membership", @payments ] ], stale
    end

    should "never list a fact Espalia writes for someone after they left" do
      as_tenant do
        @handler.leave(@grace.id, **HIBOB)
        @handler.change_title(@grace.id, "Alumni", **ESPALIA)
      end
      travel_to START + 31.days

      assert_equal [ [ @ada.id, "membership", @payments ] ], stale
    end

    should "never list a membership of a retired unit, nor confirm one" do
      as_tenant { OrgGraph::StructureCommandHandler.new.retire_unit(@payments, effective_on: "2026-02-10") }
      travel_to START + 31.days

      assert_empty stale
      assert_raises(RuntimeError, match: /retired/) { confirm(@ada, "membership", unit_id: @payments) }
    end

    should "use the tenant's own threshold" do
      travel_to START + 31.days
      @tenant.update!(org_graph_config: { staleness_days: 90 })

      assert_empty stale
    end
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      as_tenant { @handler.change_title(@grace.id, "Lead", **ESPALIA) }
      travel_to START + 3.days
      confirm(@ada, "membership", unit_id: @payments)
      as_tenant { @handler.leave(@grace.id, **HIBOB) }

      before = snapshot_read_models(OrgGraph::Projections::FactAges, @tenant)
      assert_equal 3, before[:fact_ages].size

      OrgGraph::Projections::FactAges.reset!(tenant: @tenant)
      as_tenant { assert_equal 0, OrgFactAge.count }

      Projections::Replayer.replay(projection_class: OrgGraph::Projections::FactAges, tenant: @tenant)

      assert_equal before, snapshot_read_models(OrgGraph::Projections::FactAges, @tenant)
    end
  end
end
