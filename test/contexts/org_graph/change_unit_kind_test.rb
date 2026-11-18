# frozen_string_literal: true

require "test_helper"

class OrgGraph::ChangeUnitKindTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 12, 31)
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @system = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @region, @tribe, @team, @squad, @crew = Array.new(5) { SecureRandom.uuid_v7 }
    @system.add_level(@region, "Region", effective_on: "2026-12-01")
    @system.set_level_provider(@region, "hibob", field: "work.region", effective_on: "2026-12-01")
    @system.add_level(@tribe, "Tribe", parent_ids: [], top: true, effective_on: "2026-12-01")
    @system.add_level(@team, "Team", parent_ids: [ @tribe ], top: false, effective_on: "2026-12-01")
    @system.add_level(@squad, "Squad", parent_ids: [ @team ], top: false, effective_on: "2026-12-01")
    @system.add_level(@crew, "Crew", parent_ids: [ @tribe ], top: false, effective_on: "2026-12-01")

    @commerce = create_unit("Commerce", @tribe)
    @payments = create_unit("Payments", @team, parent_id: @commerce)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  should "record the new type, the old one, the date and who changed it" do
    actor = SecureRandom.uuid_v7
    @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10", kind_changed_by_id: actor)
    event = structure_events.last

    assert_kind_of OrgGraph::Events::UnitKindChanged, event
    assert_equal({ unit_id: @payments, level_id: @crew, previous_level_id: @team, provider: "espalia",
                   effective_on: "2026-12-10", kind_changed_by_id: actor, changed_back_id: nil }, event.data.symbolize_keys)
  end

  should "write nothing when the type is unchanged" do
    assert_no_difference -> { structure_events.size } do
      @system.change_unit_kind(@payments, @team, effective_on: "2026-12-10")
    end
  end

  should "refuse a type that can't sit under the unit's parent, or at the top" do
    error = assert_raises(RuntimeError) { @system.change_unit_kind(@payments, @squad, effective_on: "2026-12-10") }
    assert_equal "Squad can't sit under Tribe", error.message

    error = assert_raises(RuntimeError) { @system.change_unit_kind(@commerce, @team, effective_on: "2026-12-10") }
    assert_equal "Team can't sit at the top", error.message
  end

  should "refuse a type its sub-units can't sit under, naming them all" do
    create_unit("Checkout", @squad, parent_id: @payments)
    create_unit("Basket", @squad, parent_id: @payments)

    error = assert_raises(RuntimeError) { @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10") }
    assert_equal "These units wouldn't fit under Crew, so move them first: Basket (Squad), Checkout (Squad)", error.message
  end

  should "leave a unit an HRIS supplies to the HRIS, and an HRIS type to its units" do
    north = SecureRandom.uuid_v7
    @system.create_unit(north, "North", level_id: @region, provider: "hibob", external_ref: "r-1", effective_on: "2026-12-01")

    error = assert_raises(RuntimeError) { @system.change_unit_kind(north, @tribe, effective_on: "2026-12-10") }
    assert_equal "hibob supplies this unit; change it there", error.message

    error = assert_raises(RuntimeError) { @system.change_unit_kind(@commerce, @region, effective_on: "2026-12-10") }
    assert_equal "hibob supplies Region units", error.message
  end

  should "refuse a type the taxonomy doesn't hold" do
    error = assert_raises(RuntimeError) { @system.change_unit_kind(@payments, SecureRandom.uuid_v7, effective_on: "2026-12-10") }
    assert_equal "That unit type doesn't exist", error.message
  end

  context "dating" do
    should "refuse a date before the unit was created, after today, or before its last change of type" do
      assert_raises(RuntimeError, match: /created on 2026-12-01/) do
        @system.change_unit_kind(@payments, @crew, effective_on: "2026-11-30")
      end
      assert_raises(RuntimeError, match: "A unit's type can't change after today") do
        @system.change_unit_kind(@payments, @crew, effective_on: "2027-01-01")
      end

      @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10")
      error = assert_raises(RuntimeError) { @system.change_unit_kind(@payments, @team, effective_on: "2026-12-09") }
      assert_equal "The unit's type last changed on 2026-12-10, so date this then or later", error.message
      assert_nothing_raised { @system.change_unit_kind(@payments, @team, effective_on: "2026-12-10") }
    end

    should "refuse a back-dated type that a sub-unit, since moved away, couldn't have sat under" do
      checkout = create_unit("Checkout", @squad, parent_id: @payments)
      other = create_unit("Billing", @team, parent_id: @commerce)
      @system.move_unit(checkout, other, effective_on: "2026-12-15")

      error = assert_raises(RuntimeError) { @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10") }
      assert_equal "On 2026-12-10, Crew wouldn't have fit: Checkout (Squad under Crew). Date the change later", error.message
      assert_nothing_raised { @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-15") }
    end

    should "refuse a back-dated type its parent before a later move couldn't have taken" do
      studio_kind = SecureRandom.uuid_v7
      @system.add_level(studio_kind, "Studio", parent_ids: [], top: true, effective_on: "2026-12-01")
      @system.set_kind_parents(@team, parent_ids: [ @tribe, studio_kind ], top: false, effective_on: "2026-12-01")
      studio = create_unit("Studio One", studio_kind)
      ledger = create_unit("Ledger", @team, parent_id: studio)
      @system.move_unit(ledger, @commerce, effective_on: "2026-12-20")

      error = assert_raises(RuntimeError) { @system.change_unit_kind(ledger, @crew, effective_on: "2026-12-10") }
      assert_equal "On 2026-12-10, Crew wouldn't have fit: Ledger (Crew under Studio). Date the change later", error.message
      assert_nothing_raised { @system.change_unit_kind(ledger, @crew, effective_on: "2026-12-20") }
    end

    should "refuse a type a unit couldn't take under a parent a move dated ahead gives it for a while" do
      studio_kind = SecureRandom.uuid_v7
      @system.add_level(studio_kind, "Studio", parent_ids: [], top: true, effective_on: "2026-12-01")
      @system.set_kind_parents(@team, parent_ids: [ @tribe, studio_kind ], top: false, effective_on: "2026-12-01")
      studio = create_unit("Studio One", studio_kind)
      retail = create_unit("Retail", @tribe)
      @system.move_unit(@payments, studio, effective_on: "2027-01-10")
      @system.move_unit(@payments, retail, effective_on: "2027-02-01")

      error = assert_raises(RuntimeError) { @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10") }
      assert_equal "On 2027-01-10, Crew wouldn't fit: Payments (Crew under Studio)", error.message
    end

    should "judge a back-dated move by the type the unit held on each day it covers" do
      studio_kind = SecureRandom.uuid_v7
      @system.add_level(studio_kind, "Studio", parent_ids: [], top: true, effective_on: "2026-12-01")
      @system.set_kind_parents(@crew, parent_ids: [ @tribe, studio_kind ], top: false, effective_on: "2026-12-01")
      studio = create_unit("Studio One", studio_kind)
      @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10")

      error = assert_raises(RuntimeError) { @system.move_unit(@payments, studio, effective_on: "2026-12-05") }
      assert_equal "On 2026-12-05, Team couldn't sit under Studio, so the change can't be dated before its rules allowed it",
                   error.message
      assert_nothing_raised { @system.move_unit(@payments, studio, effective_on: "2026-12-10") }
    end

    should "judge a back-dated change of rules by the type a unit held under its parent then" do
      retail = create_unit("Retail", @tribe)
      @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10")
      @system.move_unit(@payments, retail, effective_on: "2026-12-15")

      error = assert_raises(RuntimeError) do
        @system.set_kind_parents(@team, parent_ids: [], top: true, effective_on: "2026-12-05")
      end
      assert_equal "These units sat where this structure wouldn't allow after 2026-12-05, so date it 2026-12-10 or later: " \
                   "Payments (Team under Tribe until 2026-12-10)", error.message
      assert_nothing_raised { @system.set_kind_parents(@team, parent_ids: [], top: true, effective_on: "2026-12-10") }
    end
  end

  should "keep a type a unit once held from being removed from the taxonomy" do
    @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10")
    @system.change_unit_kind(@payments, @team, effective_on: "2026-12-11")

    error = assert_raises(RuntimeError) { @system.remove_level(@crew, effective_on: "2026-12-20") }
    assert_equal "Crew can't be removed, as it held Payments", error.message
  end

  should "keep a type a unit held for less than a day from being removed" do
    @system.change_unit_kind(@payments, @crew, effective_on: "2026-12-10")
    @system.change_unit_kind(@payments, @team, effective_on: "2026-12-10")

    error = assert_raises(RuntimeError) { @system.remove_level(@crew, effective_on: "2026-12-20") }
    assert_equal "Crew can't be removed, as it held Payments", error.message
  end

  context "authorization" do
    setup do
      @owner = create(:person, tenant: @tenant, name: "Owner")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(@owner.id, provider: "espalia", effective_on: "2026-12-01", employment_status: "employed")
      @system.add_unit_owner(@commerce, @owner.id, effective_on: "2026-12-01")
      @system.add_unit_owner(@payments, @owner.id, effective_on: "2026-12-01")
    end

    should "refuse an owner of the unit and its parent, who may still move it" do
      owner = context_for(@owner)

      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(owner).change_unit_kind(@payments, @crew, effective_on: "2026-12-10")
      end
      assert_equal "Only a tenant admin or an Org Graph editor can change a unit's type", error.message
      assert OrgGraphPolicy.new(owner, :org_graph).move_unit?(OrgUnit.find(@payments), OrgUnit.find(@commerce))
    end

    should "let an Org Graph editor and a tenant admin change it, as the person who did" do
      structure(context_for(@owner, org_graph_editor: true)).change_unit_kind(@payments, @crew, effective_on: "2026-12-10")
      assert_equal @owner.id, structure_events.last.data[:kind_changed_by_id]

      admin = create(:person, tenant: @tenant, name: "Admin")
      structure(context_for(admin, role: :admin)).change_unit_kind(@payments, @team, effective_on: "2026-12-11")
      assert_equal admin.id, structure_events.last.data[:kind_changed_by_id]
    end
  end

  private

  def create_unit(name, level_id, **options)
    SecureRandom.uuid_v7.tap { @system.create_unit(it, name, level_id:, effective_on: "2026-12-01", **options) }
  end

  def structure(actor) = OrgGraph::StructureCommandHandler.new(actor:)

  def context_for(person, role: :member, org_graph_editor: false)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person:, role:, org_graph_editor:)
    AuthorizationContext.new(user:, tenant_user:, person:)
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
