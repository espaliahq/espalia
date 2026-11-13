# frozen_string_literal: true

require "test_helper"

class OrgGraph::AuthorizationTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @department, @team = Array.new(2) { SecureRandom.uuid_v7 }
    @engineering_id, @payments_id, @product_id = Array.new(3) { SecureRandom.uuid_v7 }

    system = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    system.define_taxonomy([ { level_id: @department, name: "Department" }, { level_id: @team, name: "Team" } ],
      effective_on: "2026-01-01")
    system.create_unit(@engineering_id, "Engineering", level_id: @department, effective_on: "2026-01-01")
    system.create_unit(@payments_id, "Payments", level_id: @team, parent_id: @engineering_id, effective_on: "2026-01-01")
    system.create_unit(@product_id, "Product", level_id: @department, effective_on: "2026-01-01")

    @lead = create(:person, tenant: @tenant, name: "Lead")
    @report = create(:person, tenant: @tenant, name: "Report", manager: @lead)
    @other = create(:person, tenant: @tenant, name: "Other")
    [ @lead, @report, @other ].each do |person|
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).record_person(person.id, **ESPALIA, employment_status: "employed")
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "with no actor" do
    should "refuse to build a handler, so a path that forgets one can't skip the check" do
      [ OrgGraph::CommandHandler, OrgGraph::StructureCommandHandler ].each do |handler|
        assert_raises(ArgumentError) { handler.new }
        error = assert_raises(ArgumentError) { handler.new(actor: nil) }
        assert_match "needs an actor", error.message
        assert_raises(ArgumentError) { handler.new(actor: @lead) }
      end
    end
  end

  context "as the system" do
    should "not be checked" do
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)

      structure.rename_unit(@product_id, "Products", effective_on: "2026-02-01")
      people.change_title(@other.id, "Engineer", **ESPALIA)
      people.set_membership(@other.id, @product_id, **ESPALIA)

      assert_equal "Products", OrgUnit.find(@product_id).name
      assert OrgMembership.exists?(person_id: @other.id, unit_id: @product_id)
    end
  end

  context "as a member with no grant" do
    setup { @actor = context_for(@other) }

    should "be refused the structure and people's facts, saying who may change them" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(@actor).set_fact_provider("title", "espalia", effective_on: "2026-02-01")
      end

      assert_kind_of Pundit::NotAuthorizedError, error
      assert_match "Only a tenant admin or an Org Graph editor", error.message
      assert_raises(OrgGraph::Authorization::Refused) { people(@actor).change_title(@report.id, "Lead", **ESPALIA) }
      assert_raises(OrgGraph::Authorization::Refused) { people(@actor).record_absence(@report.id, **ESPALIA) }
    end

    should "be refused a unit, naming it" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(@actor).rename_unit(@payments_id, "Pay", effective_on: "2026-02-01")
      end

      assert_match "an owner of Payments or a unit above it", error.message
      assert_equal "Payments", OrgUnit.find(@payments_id).name
    end

    should "be refused confirming a person's fact" do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).change_title(@report.id, "Engineer", **ESPALIA)

      assert_raises(OrgGraph::Authorization::Refused) do
        people(@actor).confirm_fact(@report.id, "title", effective_on: "2026-02-02")
      end
    end

    should "be refused someone else's membership" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        people(@actor).set_membership(@report.id, @product_id, **ESPALIA)
      end

      assert_match "Report's manager chain", error.message
      assert_not OrgMembership.exists?(person_id: @report.id)
    end
  end

  [ [ "a tenant admin", { role: :admin } ], [ "an Org Graph editor", { org_graph_editor: true } ] ].each do |label, grant|
    context "as #{label}" do
      setup { @actor = context_for(@other, **grant) }

      should "change anything Espalia holds" do
        structure(@actor).set_fact_provider("title", "espalia", effective_on: "2026-02-01")
        structure(@actor).create_unit(SecureRandom.uuid_v7, "Design", level_id: @department, effective_on: "2026-02-01")
        structure(@actor).move_unit(@payments_id, @product_id, effective_on: "2026-02-01")
        people(@actor).change_title(@report.id, "Lead", **ESPALIA)
        people(@actor).set_membership(@report.id, @product_id, **ESPALIA)

        assert_equal @product_id, OrgUnit.find(@payments_id).parent_id
        assert OrgMembership.exists?(person_id: @report.id, unit_id: @product_id)
      end
    end
  end

  context "as an owner of a unit above" do
    setup do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).add_unit_owner(@engineering_id, @other.id, effective_on: "2026-01-01")
      @actor = context_for(@other)
    end

    should "change the units beneath it and their memberships" do
      squad_id = SecureRandom.uuid_v7
      structure(@actor).create_unit(squad_id, "Checkout", level_id: @team, parent_id: @engineering_id,
        effective_on: "2026-02-01")
      structure(@actor).rename_unit(@payments_id, "Pay", effective_on: "2026-02-01")
      structure(@actor).add_unit_owner(@payments_id, @lead.id, effective_on: "2026-02-01")
      people(@actor).set_membership(@report.id, @payments_id, **ESPALIA)
      people(@actor).move_membership(@report.id, @payments_id, squad_id, effective_on: "2026-02-02")

      assert_equal "Pay", OrgUnit.find(@payments_id).name
      assert OrgMembership.exists?(person_id: @report.id, unit_id: squad_id)
    end

    should "be refused the root, a unit elsewhere, and a move or succession that reaches one" do
      system = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      system.add_unit_owner(@product_id, @lead.id, effective_on: "2026-01-01")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_membership(@lead.id, @product_id, **ESPALIA)

      refusals = {
        "a unit at the root" => -> {
          structure(@actor).create_unit(SecureRandom.uuid_v7, "Design", level_id: @department, effective_on: "2026-02-01")
        },
        "rename Product" => -> { structure(@actor).rename_unit(@product_id, "P", effective_on: "2026-02-01") },
        "move beneath Product" => -> { structure(@actor).move_unit(@payments_id, @product_id, effective_on: "2026-02-01") },
        "succession naming Product" => -> {
          structure(@actor).record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments_id ],
            successor_ids: [ @product_id ], effective_on: "2026-02-01")
        },
        "retire Product" => -> { structure(@actor).retire_unit(@product_id, effective_on: "2026-02-01") },
        "own Product" => -> { structure(@actor).add_unit_owner(@product_id, @other.id, effective_on: "2026-02-01") },
        "membership of Product" => -> { people(@actor).set_membership(@report.id, @product_id, **ESPALIA) },
        "end a membership of Product" => -> {
          people(@actor).end_membership(@lead.id, @product_id, **ESPALIA)
        },
        "move a membership out of Product" => -> {
          people(@actor).move_membership(@lead.id, @product_id, @payments_id, effective_on: "2026-02-02")
        },
        "a person's facts" => -> { people(@actor).change_title(@report.id, "Lead", **ESPALIA) }
      }

      refusals.each do |label, command|
        assert_raises(OrgGraph::Authorization::Refused, label) { command.call }
      end
      assert_equal [ @lead.id ], OrgUnitOwner.where(unit_id: @product_id).pluck(:person_id)
      assert OrgMembership.exists?(person_id: @lead.id, unit_id: @product_id)
    end

    should "record a succession between units they hold, and remove an owner beneath" do
      squad_id = SecureRandom.uuid_v7
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).create_unit(squad_id, "Checkout", level_id: @team,
        parent_id: @engineering_id, effective_on: "2026-01-01")
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).add_unit_owner(@payments_id, @lead.id, effective_on: "2026-01-01")

      structure(@actor).record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments_id ],
        successor_ids: [ squad_id ], effective_on: "2026-02-01")
      structure(@actor).remove_unit_owner(@payments_id, @lead.id, effective_on: "2026-02-01")

      assert_not OrgUnitOwner.exists?(unit_id: @payments_id)
    end

    should "name themselves as the person who made the change" do
      structure(@actor).rename_unit(@payments_id, "Pay", effective_on: "2026-02-01")
      people(@actor).set_membership(@report.id, @payments_id, **ESPALIA)

      renamed = event_store.read.of_type(OrgGraph::Events::UnitRenamed).last
      placed = event_store.read.of_type(OrgGraph::Events::MembershipSet).last
      assert_equal @other.id, renamed.data[:renamed_by_id]
      assert_equal @other.id, placed.data[:set_by_id]
    end

    should "let the system move the members out when they retire a unit" do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_membership(@lead.id, @payments_id, **ESPALIA)

      structure(@actor).retire_unit(@payments_id, effective_on: "2026-03-01")

      assert_not OrgMembership.exists?(person_id: @lead.id, unit_id: @payments_id)
    end

    should "lose the rights once they leave" do
      @other.update!(status: "inactive")

      assert_raises(OrgGraph::Authorization::Refused) do
        structure(context_for(@other)).rename_unit(@payments_id, "Pay", effective_on: "2026-02-01")
      end
    end
  end

  context "in a person's manager chain" do
    setup { @actor = context_for(@lead) }

    should "set, move and end their report's memberships in units they don't own" do
      people(@actor).set_membership(@report.id, @product_id, **ESPALIA)
      people(@actor).move_membership(@report.id, @product_id, @payments_id, effective_on: "2026-02-02")
      people(@actor).end_membership(@report.id, @payments_id, provider: "espalia", effective_on: "2026-02-03")

      assert_not OrgMembership.exists?(person_id: @report.id)
    end

    should "confirm their report's membership, as the person who confirmed it" do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_membership(@report.id, @product_id, **ESPALIA)

      people(@actor).confirm_fact(@report.id, "membership", unit_id: @product_id, effective_on: "2026-02-02")

      confirmed = Rails.configuration.event_store.read.of_type(OrgGraph::Events::FactConfirmed).last
      assert_equal @lead.id, confirmed.data[:confirmed_by_id]
      assert_raises(OrgGraph::Authorization::Refused) do
        people(@actor).confirm_fact(@other.id, "membership", unit_id: @product_id, effective_on: "2026-02-02")
      end
    end

    should "be refused a move between units they don't hold for someone outside their chain" do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).add_unit_owner(@product_id, @lead.id, effective_on: "2026-01-01")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_membership(@other.id, @product_id, **ESPALIA)

      error = assert_raises(OrgGraph::Authorization::Refused) do
        people(@actor).move_membership(@other.id, @product_id, @payments_id, effective_on: "2026-02-02")
      end
      assert_match "rights over both Product and Payments", error.message
      people(@actor).end_membership(@other.id, @product_id, **ESPALIA)
    end

    should "be refused anyone else's membership and the units themselves" do
      assert_raises(OrgGraph::Authorization::Refused) { people(@actor).set_membership(@other.id, @product_id, **ESPALIA) }
      assert_raises(OrgGraph::Authorization::Refused) do
        structure(@actor).rename_unit(@product_id, "P", effective_on: "2026-02-01")
      end
    end
  end

  private

  def event_store = Rails.configuration.event_store

  def structure(actor) = OrgGraph::StructureCommandHandler.new(actor:)

  def people(actor) = OrgGraph::CommandHandler.new(actor:)

  def context_for(person, role: :member, org_graph_editor: false)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person:, role:, org_graph_editor:)
    AuthorizationContext.new(user:, tenant_user:, person:)
  end
end
