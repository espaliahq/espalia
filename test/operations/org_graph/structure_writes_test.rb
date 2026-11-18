# frozen_string_literal: true

require "test_helper"

# Declaring and withdrawing a unit's own structure, and changing its types,
# through the operations MCP and the web share (#494).
class Operations::OrgGraph::StructureWritesTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true,
                                     person: create(:person, tenant: @tenant))
    end
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def declare(**params)
    call(Operations::OrgGraph::DeclareStructure, unit_id: @org[:checkout],
                                                 levels: [ { name: "Stream" }, { name: "Lane", parent_names: [ "stream" ], top: false } ],
                                                 conversion: { @org[:squad] => "Stream" }, **params)
  end

  def level_of(unit) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[unit]).level_id }

  context "DeclareStructure" do
    should "give a unit its own types, minting their ids and converting the units beneath it" do
      result = declare

      stream, lane = result[:levels].pluck(:level_id)
      assert_equal [ "Checkout", %w[Stream Lane], { @org[:squad] => stream } ],
                   [ result[:name], result[:levels].pluck(:name), result[:conversion] ]
      assert_equal [ [ stream ], false ], result[:levels].last.values_at(:parent_ids, :top)
      assert_equal [ stream, @org[:team] ], [ level_of(:payments), level_of(:checkout) ]
      assert_not_includes [ @org[:department], @org[:team], @org[:squad] ], lane
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).last
      assert_equal [ @org[:checkout], @admin.person.id ], event.data.values_at(:structure_unit_id, :defined_by_id)
    end

    should "refuse names it can't place, a duplicate name, and a unit an HRIS supplies beneath it" do
      error = assert_raises(Operations::Base::ParameterError) { declare(conversion: { @org[:squad] => "Pod" }) }
      assert_equal "The conversion names a type, \"Pod\", that isn't in the structure", error.message

      error = assert_raises(Operations::Base::ParameterError) { declare(levels: [ { name: "Stream" }, { name: "stream" } ]) }
      assert_equal "Each unit type needs its own name", error.message

      error = assert_raises(Operations::Base::ParameterError) { declare(levels: [ { name: "Stream" } ], conversion: {}) }
      assert_equal "Say what Squad units become", error.message
      assert_equal @org[:squad], level_of(:payments)
    end

    should "leave a unit's structure to a tenant admin" do
      error = assert_raises(Pundit::NotAuthorizedError) { declare(as: @editor) }

      assert_equal "Only a tenant admin can change Checkout's structure", error.message
      assert_equal @org[:squad], level_of(:payments)
    end
  end

  context "with a structure declared" do
    setup { @stream, @lane = declare[:levels].pluck(:level_id) }

    should "add, rule and remove its types without touching the top structure" do
      pod = call(Operations::OrgGraph::AddLevel, name: "Pod", parent_ids: [ @lane ], structure_unit_id: @org[:checkout])
      assert_equal [ @org[:checkout], %w[Stream Lane Pod] ], [ pod[:structure_unit_id], pod[:levels].pluck(:name) ]

      ruled = call(Operations::OrgGraph::SetKindParents, level_id: pod[:level_id], parent_ids: [ @stream ], top: false,
                                                         structure_unit_id: @org[:checkout])
      assert_equal [ @stream ], ruled[:parent_ids]

      removed = call(Operations::OrgGraph::RemoveLevel, level_id: pod[:level_id], structure_unit_id: @org[:checkout])
      assert_equal %w[Stream Lane], removed[:levels].pluck(:name)
      assert_equal %w[Department Team Squad], ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_structure.pluck(:name) }
    end

    should "leave its types to a tenant admin" do
      error = assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::OrgGraph::AddLevel, as: @editor, name: "Pod", structure_unit_id: @org[:checkout])
      end
      assert_equal "Only a tenant admin can change Checkout's structure", error.message
    end

    should "withdraw it, converting the units beneath it back" do
      result = call(Operations::OrgGraph::WithdrawStructure, unit_id: @org[:checkout], conversion: { @stream => @org[:squad] })

      assert_equal({ @stream => @org[:squad] }, result[:conversion])
      assert_equal @org[:squad], level_of(:payments)
      assert_empty ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.in_structure(@org[:checkout]) }
    end

    should "refuse a withdrawal that leaves a held type out" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::WithdrawStructure, unit_id: @org[:checkout], conversion: {})
      end
      assert_equal "Say what Stream units become", error.message
    end
  end
end
