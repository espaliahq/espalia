# frozen_string_literal: true

require "test_helper"

class OrgGraph::AsOfTest < ActiveSupport::TestCase
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
      @handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed",
                             title: "Engineer", level: "L3", manager_id: @grace.id, site: "Sydney", country: "AU",
                             fte: 1.0, employment_type: "Full-time")
      @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0, role: "Lead")
      @structure.add_unit_owner(@payments, @ada.id, effective_on: "2026-02-01")

      user = create(:user)
      @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def as_of(date, known_on: nil)
    as_tenant { OrgGraph::AsOf.new(context: @context, date: Date.iso8601(date), known_on: known_on && Date.iso8601(known_on)).call }
  end

  def placements(snapshot) = snapshot.memberships.map { [ it.person_id, it.unit_id ] }

  should "read the roster, the structure and the memberships in effect on a day" do
    snapshot = as_of("2026-02-15")

    ada = snapshot.people.sole
    assert_equal [ @ada.id, "Engineer", "L3", @grace.id, "Sydney", "AU", 1.0, "Full-time" ],
                 [ ada.id, ada.title, ada.level, ada.manager_id, ada.site, ada.country, ada.fte, ada.employment_type ]
    assert_equal "espalia", ada.providers.fetch("title")
    assert_not_includes ada.providers.keys, "employment_status"

    assert_equal %w[Engineering Payments Platform], snapshot.units.map(&:name)
    payments = snapshot.units.find { it.id == @payments }
    assert_equal [ @engineering, @squads, [ @ada.id ] ], [ payments.parent_id, payments.level_id, payments.owner_ids ]
    assert_nil snapshot.units.find { it.id == @engineering }.parent_id

    assert_equal [ OrgGraph::AsOf::Membership.new(person_id: @ada.id, unit_id: @payments, allocation: 1.0, role: "Lead") ],
                 snapshot.memberships
  end

  should "name people by id only" do
    assert_not_includes as_of("2026-02-15").to_h.to_s, @ada.name
  end

  should "leave out who was not yet employed, and units not yet created" do
    snapshot = as_of("2026-01-15")

    assert_empty snapshot.people
    assert_empty snapshot.memberships
    assert_equal 3, snapshot.units.size
    assert_empty as_of("2025-12-31").units
  end

  should "include the changes already recorded for a later day" do
    as_tenant do
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-06-01")
      @handler.record_person(@grace.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "pending", title: "Designer")
      @handler.join(@grace.id, **ESPALIA, effective_on: "2026-06-01")
    end

    assert_equal [ @ada.id ], as_of("2026-05-31").people.map(&:id)
    assert_equal [ [ @ada.id, @payments ] ], placements(as_of("2026-05-31"))

    june = as_of("2026-06-01")
    assert_equal [ @ada.id, @grace.id ].sort, june.people.map(&:id)
    assert_equal [ [ @ada.id, @platform ] ], placements(june)
  end

  should "drop a leaver from the day after their leaving date, with their memberships and ownership" do
    as_tenant { @handler.leave(@ada.id, **ESPALIA, effective_on: "2026-04-30") }

    april = as_of("2026-04-30")
    assert_equal [ [ @ada.id ], [] ], [ april.people.map(&:id), april.left_ids ]
    may = as_of("2026-05-01")
    assert_empty may.people
    assert_equal [ @ada.id ], may.left_ids
    assert_empty may.memberships
    assert_empty may.units.find { it.id == @payments }.owner_ids
  end

  should "drop a retired unit from the day after it retires, with its memberships" do
    as_tenant { @structure.retire_unit(@payments, effective_on: "2026-04-30") }

    assert_includes as_of("2026-04-30").units.map(&:id), @payments
    may = as_of("2026-05-01")
    assert_equal %w[Engineering Platform], may.units.map(&:name)
    assert_empty may.memberships
  end

  should "hold a retired unit apart from the live ones, as it last stood, and a succession from the day it is recorded" do
    succession = SecureRandom.uuid_v7
    as_tenant do
      @structure.record_succession(succession, predecessor_ids: [ @payments ], successor_ids: [ @platform ],
                                               effective_on: "2026-04-30", retire_predecessors: true)
    end

    april = as_of("2026-04-29")
    assert_equal [ [], [] ], [ april.retired_units, april.successions ]
    may = as_of("2026-05-01")
    assert_equal %w[Engineering Platform], may.units.map(&:name)
    assert_equal [ [ @payments, "Payments", @engineering, @squads ] ], may.retired_units.map { [ it.id, it.name, it.parent_id, it.level_id ] }
    assert_equal [ OrgGraph::AsOf::Succession.new(id: succession, predecessor_ids: [ @payments ], successor_ids: [ @platform ]) ],
                 may.successions
  end

  should "read what was known on an earlier day, leaving out a correction learned since" do
    travel 10.days
    as_tenant { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-02-01") }

    assert_equal "Senior Engineer", as_of("2026-02-15").people.sole.title
    known = as_of("2026-02-15", known_on: "2026-02-05")
    assert_equal [ "Engineer", Date.new(2026, 2, 5) ], [ known.people.sole.title, known.known_on ]
  end

  should "read the kinds of unit, and where each may sit, as they stood on a day" do
    guild = SecureRandom.uuid_v7
    travel_to Time.zone.parse("2026-04-02 09:00")
    as_tenant do
      @structure.add_level(guild, "Guild", effective_on: "2026-03-01")
      @structure.reorder_levels([ guild, @departments, @squads ], effective_on: "2026-03-01")
      @structure.set_level_provider(guild, "hibob", effective_on: "2026-04-01", field: "work.guild")
    end

    assert_empty as_of("2025-12-31").kinds
    assert_equal [ [ @departments, "Department", "espalia", [] ], [ @squads, "Squad", "espalia", [ @departments ] ] ],
                 as_of("2026-02-15").kinds.map { [ it.id, it.name, it.provider, it.parent_ids ] }
    assert_equal [ [ guild, "espalia" ], [ @departments, "espalia" ] ],
                 as_of("2026-03-15").kinds.first(2).map { [ it.id, it.provider ] }
    assert_equal [ [], [ guild, @departments ] ], as_of("2026-04-01").kinds.values_at(0, 2).map(&:parent_ids)
    assert_equal "hibob", as_of("2026-04-01").kinds.first.provider
  end

  should "refuse someone outside the tenant" do
    @context = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { as_of("2026-02-15") }
  end
end
