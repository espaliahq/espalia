# frozen_string_literal: true

require "test_helper"

class OrgGraph::ChangeBackHandlerTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @divisions, @departments, @squads = Array.new(3) { SecureRandom.uuid_v7 }
    @payments, @platform, @engineering = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to Time.zone.parse("2026-02-01 09:00")
    as_tenant do
      @ada, @lead = create_list(:person, 2, tenant: @tenant)
      @structure.define_taxonomy([ { level_id: @divisions, name: "Division" }, { level_id: @departments, name: "Department" },
                                  { level_id: @squads, name: "Squad" } ],
        effective_on: "2026-01-01")
      @structure.create_unit(@engineering, "Engineering", level_id: @departments, effective_on: "2026-01-01")
      @structure.create_unit(@payments, "Payments", level_id: @squads, effective_on: "2026-01-01")
      @structure.create_unit(@platform, "Platform", level_id: @squads, effective_on: "2026-01-01")
      [ @ada, @lead ].each { |person| @handler.record_person(person.id, **ESPALIA, employment_status: "employed") }
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def latest(unit_id) = as_tenant { OrgUnitActivity.for_unit(unit_id).first }

  def change_back(entry, actor: SYSTEM, **options)
    as_tenant { OrgGraph::ChangeBackHandler.new(actor:).change_back(entry, **options) }
  end

  def membership(person, unit_id) = as_tenant { OrgMembership.find_by(person:, unit_id:) }

  def actor_for(person)
    user = create(:user)
    as_tenant { AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant: @tenant, user:, person:), person:) }
  end

  should "end a membership it set, and keep both entries, the first marked changed back" do
    as_tenant { @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0) }
    set = latest(@payments)

    travel_to Time.zone.parse("2026-02-05 10:00")
    change_back(set)

    assert_nil membership(@ada, @payments)
    undo = latest(@payments)
    assert_equal [ "MembershipEnded", set.event_id, Date.new(2026, 2, 1), Time.zone.parse("2026-02-05 10:00") ],
      [ undo.event_type, undo.changes_back_id, undo.effective_on, undo.learned_at ]
    assert_equal undo.event_id, set.reload.changed_back_by_id
    assert_equal 3, as_tenant { OrgUnitActivity.for_unit(@payments).count }
  end

  should "take effect on a date the caller names" do
    as_tenant { @structure.rename_unit(@payments, "Payments Core", effective_on: "2026-02-01") }

    change_back(latest(@payments), effective_on: "2026-03-01")

    assert_equal Date.new(2026, 3, 1), latest(@payments).effective_on
  end

  should "refuse to move back someone who has since left, and write nothing" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01")
      @handler.leave(@ada.id, **ESPALIA)
    end
    moved = latest(@platform)

    assert_raises(RuntimeError, match: "can't move back") { change_back(moved) }
    assert membership(@ada, @platform)
    assert_not moved.reload.changed_back?
  end

  should "restore a membership's earlier terms, or the membership itself once ended" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
      @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 0.5, role: "Lead")
    end
    change_back(latest(@payments))
    assert_equal [ 1.0, nil ], [ membership(@ada, @payments).allocation, membership(@ada, @payments).role ]

    as_tenant { @handler.end_membership(@ada.id, @payments, **ESPALIA) }
    change_back(latest(@payments))
    assert_equal 1.0, membership(@ada, @payments).allocation
  end

  should "move a membership back, from either unit's entry" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01")
    end
    change_back(latest(@payments))
    assert membership(@ada, @payments)
    assert_nil membership(@ada, @platform)

    as_tenant { @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01") }
    change_back(latest(@platform))
    assert membership(@ada, @payments)
  end

  should "undo a rename, a unit move and an owner change" do
    as_tenant do
      @structure.rename_unit(@payments, "Payments Core", effective_on: "2026-02-01")
      @structure.move_unit(@payments, @engineering, effective_on: "2026-02-01")
      @structure.add_unit_owner(@payments, @lead.id, effective_on: "2026-02-01")
    end

    3.times { change_back(as_tenant { OrgUnitActivity.for_unit(@payments).where(changed_back_by_id: nil, changes_back_id: nil).first }) }

    unit = as_tenant { OrgUnit.find(@payments) }
    assert_equal [ "Payments", nil ], [ unit.name, unit.parent_id ]
    assert_not as_tenant { OrgUnitOwner.exists?(unit_id: @payments) }
  end

  should "refuse a creation, a change already changed back, and one a later change overtook" do
    as_tenant { @handler.set_membership(@ada.id, @payments, **ESPALIA) }
    created = as_tenant { OrgUnitActivity.for_unit(@payments).find_by(event_type: "UnitCreated") }
    assert_raises(RuntimeError, match: "Unit Created can't be changed back") { change_back(created) }

    set = latest(@payments)
    as_tenant { @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 0.5) }
    assert_raises(RuntimeError, match: "later change") { change_back(set) }

    overtaking = latest(@payments)
    change_back(overtaking)
    assert_raises(RuntimeError, match: "already") { change_back(overtaking.reload) }
  end

  should "refuse a move overtaken in the unit it left, even while the other unit's entry is latest" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01")
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
    end

    assert_raises(RuntimeError, match: "later change") { change_back(latest(@platform)) }
  end

  should "check for a later change only once it holds the lock ordinary writes take" do
    as_tenant { @structure.rename_unit(@payments, "Payments Core", effective_on: "2026-02-01") }
    renamed = latest(@payments)
    repository = OrgGraph::Repository.new
    structure = @structure
    repository.define_singleton_method(:lock_structure) do
      structure.rename_unit(renamed.unit_id, "Payments Next", effective_on: "2026-02-01")
      super()
    end

    assert_raises(RuntimeError, match: "later change") do
      as_tenant { OrgGraph::ChangeBackHandler.new(actor: SYSTEM, repository:).change_back(renamed) }
    end
    assert_not renamed.reload.changed_back?
  end

  should "refuse a change another provider supplied" do
    hibob_unit = SecureRandom.uuid_v7
    as_tenant do
      @structure.set_level_provider(@divisions, "hibob", effective_on: "2026-01-01")
      @structure.create_unit(hibob_unit, "Design", level_id: @divisions, effective_on: "2026-01-01",
        provider: "hibob", external_ref: "d-1")
      @handler.set_membership(@ada.id, hibob_unit, provider: "hibob", effective_on: "2026-02-01")
    end

    assert_raises(RuntimeError, match: "hibob supplies this") { change_back(latest(hibob_unit)) }
    assert membership(@ada, hibob_unit)
  end

  should "change back as the actor, under the rights to make the inverse change" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
      @structure.add_unit_owner(@payments, @lead.id, effective_on: "2026-02-01")
      @handler.set_membership(@ada.id, @platform, **ESPALIA)
    end

    assert_raises(OrgGraph::Authorization::Refused) { change_back(latest(@platform), actor: actor_for(@lead)) }

    as_tenant { @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 0.5) }
    change_back(latest(@payments), actor: actor_for(@lead))
    assert_equal @lead.id, latest(@payments).actor_id
  end

  context "#change_back_group" do
    setup do
      @grace = as_tenant { create(:person, tenant: @tenant) }
      as_tenant do
        @handler.record_person(@grace.id, **ESPALIA, employment_status: "employed")
        [ @ada, @grace ].each { |person| @handler.set_membership(person.id, @payments, **ESPALIA) }
      end
    end

    should "reverse every part, newest first, under one new cause" do
      as_tenant do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        request.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01")
        request.move_membership(@ada.id, @platform, @engineering, effective_on: "2026-02-01")
        request.end_membership(@grace.id, @payments, **ESPALIA)
      end

      change_back_group("request-1")

      assert membership(@ada, @payments)
      assert_nil membership(@ada, @engineering)
      assert membership(@grace, @payments)
      parts = as_tenant { OrgUnitActivity.caused_by("request-1").to_a }
      assert parts.all?(&:changed_back?)
      inverses = as_tenant { OrgUnitActivity.where(changes_back_id: parts.map(&:event_id)).distinct.pluck(:correlation_id) }
      assert_equal 1, inverses.size
      assert_not_equal "request-1", inverses.first
    end

    should "write the inverses under the request's cause when there is one" do
      as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1").end_membership(@ada.id, @payments, **ESPALIA) }

      AuditMetadata.with(acting_via: :web, correlation_id: "request-2") { change_back_group("request-1") }

      assert_equal "request-2", latest(@payments).cause_id
    end

    should "refuse once one part has been changed back alone, and point to changing back the rest one at a time" do
      as_tenant do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        [ @ada, @grace ].each { |person| request.end_membership(person.id, @payments, **ESPALIA) }
      end
      change_back(as_tenant { OrgUnitActivity.caused_by("request-1").first })

      assert_raises(RuntimeError, match: "one entry at a time") { change_back_group("request-1") }
    end

    should "refuse an approved split as a whole, naming the part that can't be changed back" do
      billing = SecureRandom.uuid_v7
      as_tenant do
        @structure.create_unit(billing, "Billing", level_id: @squads, effective_on: "2026-01-01")
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM, cause_id: "approval-1").apply_succession(
          SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ billing, @platform ],
          placements: { @ada.id => billing, @grace.id => @platform }, effective_on: "2026-07-01"
        )
      end

      assert_raises(RuntimeError, match: "can't be changed back") { change_back_group("approval-1") }
      assert membership(@ada, billing)
      assert_not(as_tenant { OrgUnitActivity.caused_by("approval-1").any?(&:changed_back?) })
    end

    should "refuse the whole group once a change from outside it has overtaken any part" do
      as_tenant do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        request.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01")
        request.move_membership(@grace.id, @payments, @platform, effective_on: "2026-02-01")
        @handler.set_membership(@grace.id, @platform, **ESPALIA, allocation: 0.5)
      end

      assert_raises(RuntimeError, match: "later change") { change_back_group("request-1") }
      assert membership(@ada, @platform)
    end

    should "refuse a group still being written, rather than reverse a part it holds no lock for" do
      request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
      as_tenant { request.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01") }
      repository = OrgGraph::Repository.new
      grace, payments, platform = @grace, @payments, @platform
      repository.define_singleton_method(:lock_person) do |person_id|
        super(person_id)
        request.move_membership(grace.id, payments, platform, effective_on: "2026-02-01") if person_id != grace.id
      end

      assert_raises(RuntimeError, match: "still being written") do
        as_tenant { OrgGraph::ChangeBackHandler.new(actor: SYSTEM, repository:).change_back_group("request-1") }
      end
      assert membership(@ada, @platform)
    end

    should "lock the structure before any person, and the people in a fixed order" do
      as_tenant do
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM, cause_id: "request-1")
          .rename_unit(@payments, "Payments Core", effective_on: "2026-02-01")
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        [ @grace, @ada ].each { |person| request.move_membership(person.id, @payments, @platform, effective_on: "2026-02-01") }
      end
      repository = OrgGraph::Repository.new
      locked = []
      repository.define_singleton_method(:lock_stream) do |stream|
        locked << stream
        super(stream)
      end

      as_tenant { OrgGraph::ChangeBackHandler.new(actor: SYSTEM, repository:).change_back_group("request-1") }

      people = [ @ada, @grace ].map(&:id).sort.map { |id| EventStreamNaming.person_stream(id, tenant: @tenant) }
      assert_equal [ EventStreamNaming.org_structure_stream(tenant: @tenant), *people ], locked.uniq.first(3)
    end
  end

  def change_back_group(cause_id, actor: SYSTEM)
    as_tenant { OrgGraph::ChangeBackHandler.new(actor:).change_back_group(cause_id) }
  end
end
