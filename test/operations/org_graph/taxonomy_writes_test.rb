# frozen_string_literal: true

require "test_helper"

# Adding, reordering and removing levels (#127, #148), so the settings screen and
# MCP change the taxonomy through the same commands.
class Operations::OrgGraph::TaxonomyWritesTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true,
                                     person: create(:person, tenant: @tenant))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
    end
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def level_names = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_first.pluck(:name) }

  def level_ids = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_first.pluck(:id) }

  def nothing_offered = { plan_id: @plan_id, scenario_id: @scenario_id, undo: nil, redo: nil }

  def undo_step = call(Operations::TeamPlanning::UndoStep, plan_id: @plan_id, scenario_id: @scenario_id)

  def assert_refused_bringing_back(&)
    error = assert_raises(Operations::Base::ParameterError, &)
    assert_equal "This change places a unit of a type that has been removed, so it can't be brought back", error.message
    assert_empty ActsAsTenant.with_tenant(@tenant) { TeamPlanningOverride.where(plan_id: @plan_id, subject_id: @unit_id) }
  end

  def scope_to_a_unit_without_the_ledger
    payments = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find_by!(name: "Payments").id }
    call(Operations::TeamPlanning::SetPlanScope, plan_id: @plan_id, unit_ids: [ payments ])
  end

  def assert_refused_as_out_of_scope(&)
    error = assert_raises(Operations::Base::ParameterError, &)
    assert_equal "This unit is outside the units this plan covers. Place it in one of its units first.", error.message
    assert_empty ActsAsTenant.with_tenant(@tenant) { TeamPlanningOverride.where(plan_id: @plan_id, subject_id: @unit_id) }
  end

  def kind_rules(level_id)
    kind = ActsAsTenant.with_tenant(@tenant) { ::OrgGraph::Repository.new.load_structure.taxonomy.kind(level_id) }
    [ kind.parent_ids, kind.top ]
  end

  context "AddLevel" do
    should "add a level Espalia holds at the bottom, with the caller as actor" do
      result = call(Operations::OrgGraph::AddLevel, name: " Guild ", effective_on: "2026-11-01")

      assert_equal %w[Department Team Squad Guild], level_names
      assert_equal "Guild", result[:name]
      assert_equal "2026-11-01", result[:effective_on]
      assert_equal({ level_id: result[:level_id], name: "Guild", provider: "espalia" }, result[:levels].last)
      assert_equal "hibob", result[:levels].first[:provider]
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).last
      assert_equal @admin.person.id, event.data[:defined_by_id]
    end

    should "refuse a name another level has, whatever its case" do
      error = assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::AddLevel, name: "squad") }

      assert_equal "There is already a level called Squad", error.message
      assert_equal %w[Department Team Squad], level_names
    end

    should "leave the taxonomy to a tenant admin" do
      [ @editor, @member ].each do |caller|
        assert_raises(Pundit::NotAuthorizedError) { call(Operations::OrgGraph::AddLevel, as: caller, name: "Guild") }
      end
      assert_equal %w[Department Team Squad], level_names
    end
  end

  context "ReorderLevels" do
    setup do
      @guild = call(Operations::OrgGraph::AddLevel, name: "Guild")[:level_id]
      @department, @team, @squad = level_ids.first(3)
    end

    should "move a level past one that holds no units" do
      result = call(Operations::OrgGraph::ReorderLevels, level_ids: [ @department, @team, @guild, @squad ])

      assert_equal %w[Department Team Guild Squad], level_names
      assert_equal %w[Department Team Guild Squad], result[:levels].pluck(:name)
    end

    should "keep a level the HRIS provides in its place, naming the provider" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::ReorderLevels, level_ids: [ @guild, @department, @team, @squad ])
      end

      assert_equal "Department comes from HiBob, so its place is set there", error.message
      assert_equal %w[Department Team Squad Guild], level_names
    end

    should "keep two levels that hold units in their order, naming them" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::ReorderLevels, level_ids: [ @department, @squad, @team, @guild ])
      end

      assert_equal "Team and Squad both hold units, so Team must stay above Squad", error.message
      assert_equal %w[Department Team Squad Guild], level_names
    end

    should "refuse an order that leaves out a level or names one twice" do
      [ [ @department, @team, @squad ], [ @department, @team, @squad, @squad ],
        [ @department, @team, @squad, SecureRandom.uuid_v7 ], [] ].each do |order|
        assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::ReorderLevels, level_ids: order) }
      end
    end

    should "leave the taxonomy to a tenant admin" do
      assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::OrgGraph::ReorderLevels, as: @editor, level_ids: [ @department, @team, @guild, @squad ])
      end
      assert_equal %w[Department Team Squad Guild], level_names
    end
  end

  context "AddLevel with rules" do
    setup { @department, @team, @squad = level_ids.first(3) }

    should "state the parents it lists, off the top unless asked" do
      guild = call(Operations::OrgGraph::AddLevel, name: "Guild", parent_ids: [ @team.upcase ])[:level_id]

      assert_equal [ [ @team ], false ], kind_rules(guild)
    end

    should "take the top it is given" do
      guild = call(Operations::OrgGraph::AddLevel, name: "Guild", parent_ids: [ @team ], top: true)[:level_id]

      assert_equal [ [ @team ], true ], kind_rules(guild)
    end

    should "keep the parents above it when given only the top" do
      guild = call(Operations::OrgGraph::AddLevel, name: "Guild", top: false)[:level_id]

      assert_equal [ [ @department, @team, @squad ], false ], kind_rules(guild)
    end

    should "refuse a parent outside the taxonomy, adding nothing" do
      stranger = SecureRandom.uuid_v7
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::AddLevel, name: "Guild", parent_ids: [ stranger ])
      end

      assert_equal "Not in the taxonomy: #{stranger}", error.message
      assert_not_includes level_names, "Guild"
    end
  end

  context "SetKindParents" do
    setup do
      @guild = call(Operations::OrgGraph::AddLevel, name: "Guild")[:level_id]
      @department, @team, @squad = level_ids.first(3)
    end

    should "replace a type's parents and top, with the caller as actor" do
      result = call(Operations::OrgGraph::SetKindParents, level_id: @guild, parent_ids: [ @guild, @team, @guild ], top: false)

      assert_equal [ [ @team, @guild ], false ], kind_rules(@guild)
      assert_equal({ level_id: @guild, name: "Guild", parent_ids: [ @team, @guild ], top: false, effective_on: Date.current.iso8601 },
                   result.except(:levels))
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).last
      assert_equal @admin.person.id, event.data[:defined_by_id]
    end

    should "refuse a list that strands live units, naming them" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::SetKindParents, level_id: @squad, parent_ids: [ @guild ], top: true)
      end

      assert_equal "These units wouldn't fit this structure, so move them first: Payments (Squad under Team)", error.message
    end

    should "hold a type an HRIS provides to the HRIS rule, naming the HRIS" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::SetKindParents, level_id: @department, parent_ids: [ @team ], top: true)
      end
      assert_equal "Department can sit only at the top, or under one type above it that an HRIS provides, while it comes from HiBob",
                   error.message

      call(Operations::OrgGraph::SetKindParents, level_id: @department, parent_ids: [], top: true)
      assert_equal [ [], true ], kind_rules(@department)
    end

    should "leave the rules to a tenant admin" do
      [ @editor, @member ].each do |caller|
        assert_raises(Pundit::NotAuthorizedError) do
          call(Operations::OrgGraph::SetKindParents, as: caller, level_id: @guild, parent_ids: [], top: true)
        end
      end
    end
  end

  context "RemoveLevel" do
    setup do
      @guild = call(Operations::OrgGraph::AddLevel, name: "Guild")[:level_id]
      @department, @team, @squad = level_ids.first(3)
    end

    should "remove a level no unit has held, with the caller as actor" do
      result = call(Operations::OrgGraph::RemoveLevel, level_id: @guild, effective_on: Date.current.iso8601)

      assert_equal %w[Department Team Squad], level_names
      assert_equal({ level_id: @guild, name: "Guild", effective_on: Date.current.iso8601 }, result.except(:levels))
      assert_equal %w[Department Team Squad], result[:levels].pluck(:name)
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).last
      assert_equal @admin.person.id, event.data[:defined_by_id]
    end

    context "that a plan places a unit at" do
      setup do
        @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: Date.current.iso8601)[:plan_id]
        @scenario_id = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1",
                                                                    ends_on: (Date.current + 90).iso8601)[:scenario_id]
        @unit_id = call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id: @scenario_id, name: "Ledger",
                                                           top_level: true, level_id: @guild)[:unit_id]
      end

      should "refuse to undo a clear of the unit once its level is gone" do
        call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @scenario_id, subject_id: @unit_id, facet: "unit")
        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)

        assert_refused_bringing_back { call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @scenario_id) }
      end

      should "refuse to redo the unit once its level is gone" do
        call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @scenario_id)
        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)

        assert_refused_bringing_back { call(Operations::TeamPlanning::RedoChange, plan_id: @plan_id, scenario_id: @scenario_id) }
      end

      should "refuse an undo outside a scoped plan's units as out of scope, though its level is gone" do
        call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @scenario_id, subject_id: @unit_id, facet: "unit")
        scope_to_a_unit_without_the_ledger
        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)

        assert_refused_as_out_of_scope { call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @scenario_id) }
      end

      should "refuse a redo outside a scoped plan's units as out of scope, though its level is gone" do
        call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @scenario_id)
        scope_to_a_unit_without_the_ledger
        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)

        assert_refused_as_out_of_scope { call(Operations::TeamPlanning::RedoChange, plan_id: @plan_id, scenario_id: @scenario_id) }
      end

      should "stop offering Undo of a clear of the unit once its level is gone" do
        call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @scenario_id, subject_id: @unit_id, facet: "unit")
        assert undo_step[:undo]

        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)
        assert_equal nothing_offered, undo_step
      end

      should "stop offering Redo of the unit once its level is gone" do
        call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @scenario_id)
        assert undo_step[:redo]

        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)
        assert_equal nothing_offered, undo_step
      end

      should "keep the level while the plan is live, counting the plans" do
        error = assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::RemoveLevel, level_id: @guild) }

        assert_equal "Guild can't be removed, as 1 live plan places units of this type. Change or archive that plan first, " \
                     "or delete it if no one can edit it any more",
                     error.message
        assert_includes level_names, "Guild"
      end

      should "keep the level while the plans' overrides are being rebuilt" do
        overrides = TeamPlanning::Projections::Overrides::PROJECTION_NAME
        rebuilding = lambda do |*names, &block|
          raise ProjectionVersion::Rebuilding if names.include?(overrides)

          block.call
        end
        error = ProjectionVersion.stub(:unless_rebuilding, rebuilding) do
          assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::RemoveLevel, level_id: @guild) }
        end

        assert_equal "The Org Graph is being rebuilt; try again in a minute.", error.message
        assert_includes level_names, "Guild"
      end

      should "remove the level once the plan is archived" do
        call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id)

        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)
        assert_not_includes level_names, "Guild"
      end

      should "keep the plan archived once its level is gone" do
        call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id)
        call(Operations::OrgGraph::RemoveLevel, level_id: @guild)

        error = assert_raises(Operations::Base::ParameterError) { call(Operations::TeamPlanning::RestorePlan, plan_id: @plan_id) }

        assert_equal "This plan places 1 unit of a type that has been removed, so it can't be restored. " \
                     "Delete it instead, or copy what you need into another plan", error.message
        assert ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find(@plan_id).archived? }
      end

      should "restore the plan while its level stays" do
        call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id)

        assert_equal false, call(Operations::TeamPlanning::RestorePlan, plan_id: @plan_id)[:archived]
      end
    end

    should "keep a level that holds units, naming them" do
      error = assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::RemoveLevel, level_id: @team) }

      assert_equal "Team can't be removed, as it holds Checkout and Platform", error.message
      assert_includes level_names, "Team"
    end

    should "keep a level whose only unit is retired, naming it" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .retire_unit(@org[:payments], effective_on: Date.current)
      end

      error = assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::RemoveLevel, level_id: @squad) }

      assert_equal "Squad can't be removed, as it held Payments", error.message
      assert_includes level_names, "Squad"
    end

    should "keep a level an HRIS provides until it is handed back, naming the provider" do
      error = assert_raises(Operations::Base::ParameterError) { call(Operations::OrgGraph::RemoveLevel, level_id: @department) }

      assert_equal "Department comes from HiBob; hand it back to Espalia before removing it", error.message
    end

    should "refuse a level that isn't in the taxonomy" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::RemoveLevel, level_id: SecureRandom.uuid_v7)
      end

      assert_equal "Level is not in the taxonomy", error.message
    end

    should "leave the taxonomy to a tenant admin" do
      [ @editor, @member ].each do |caller|
        assert_raises(Pundit::NotAuthorizedError) { call(Operations::OrgGraph::RemoveLevel, as: caller, level_id: @guild) }
      end
      assert_includes level_names, "Guild"
    end
  end
end
