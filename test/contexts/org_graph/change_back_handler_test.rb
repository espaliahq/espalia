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

  should "refuse to move back, or bring back, someone who has since left, and write nothing" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01")
      @handler.leave(@ada.id, **ESPALIA)
    end
    moved = as_tenant { OrgUnitActivity.for_unit(@platform).find_by!(event_type: "MembershipMoved") }
    ended = latest(@platform)

    assert_equal "MembershipEnded", ended.event_type
    assert_raises(RuntimeError, match: "A later change has replaced this one") { change_back(moved) }
    assert_raises(RuntimeError, match: "can't join a unit") { change_back(ended) }
    assert_nil membership(@ada, @platform)
    assert_not moved.reload.changed_back?
    assert_not ended.reload.changed_back?
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
end
