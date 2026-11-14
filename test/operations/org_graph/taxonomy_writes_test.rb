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

  context "RemoveLevel" do
    setup do
      @guild = call(Operations::OrgGraph::AddLevel, name: "Guild")[:level_id]
      @department, @team, @squad = level_ids.first(3)
    end

    should "remove a level no unit has held, with the caller as actor" do
      result = call(Operations::OrgGraph::RemoveLevel, level_id: @guild, effective_on: "2026-11-01")

      assert_equal %w[Department Team Squad], level_names
      assert_equal({ level_id: @guild, name: "Guild", effective_on: "2026-11-01" }, result.except(:levels))
      assert_equal %w[Department Team Squad], result[:levels].pluck(:name)
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).last
      assert_equal @admin.person.id, event.data[:defined_by_id]
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
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::RemoveLevel, level_id: SecureRandom.uuid_v7)
      end
    end

    should "leave the taxonomy to a tenant admin" do
      [ @editor, @member ].each do |caller|
        assert_raises(Pundit::NotAuthorizedError) { call(Operations::OrgGraph::RemoveLevel, as: caller, level_id: @guild) }
      end
      assert_includes level_names, "Guild"
    end
  end
end
