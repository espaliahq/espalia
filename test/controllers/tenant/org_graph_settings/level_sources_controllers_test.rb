# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphSettings::LevelSourcesControllersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TEAM = Hris::Field.new(id: "work.customColumns.column_team", name: "Team", kind: :list)

  FakeAdapter = Struct.new(:values) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = [ TEAM ]
    def read_field(_field_id, kind:, alongside: nil) = values
  end

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @admin_user = create(:user)
    @member_user = create(:user)
    @squad_id = SecureRandom.uuid_v7
    @tribe_id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-1")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: @tribe_id, name: "Tribe" }, { level_id: @squad_id, name: "Squad" } ],
                                effective_on: Date.current)
      structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: @squad_id, effective_on: Date.current)
    end
    @adapter = FakeAdapter.new({ "hb-1" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments") })
  end

  def level(id) = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.find(id) }

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "read an empty level from an HRIS field, and hold it in Espalia again" do
      patch tenant_org_graph_settings_level_provider_path(@tribe_id), params: { provider: "hibob", field: TEAM.id }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Tribe is now read from the HiBob field you chose.", flash[:notice]
      assert_equal [ "hibob", TEAM.id ], level(@tribe_id).then { [ it.provider, it.provider_field ] }

      patch tenant_org_graph_settings_level_provider_path(@tribe_id), params: { provider: "espalia" }
      assert_equal "Tribe now comes from Espalia.", flash[:notice]
    end

    should "say why a level that holds units can't change hands here" do
      patch tenant_org_graph_settings_level_provider_path(@squad_id), params: { provider: "hibob", field: TEAM.id }

      assert_match(/\ASquad did not change: .*hand it over instead/, flash[:alert])
      assert_equal "espalia", level(@squad_id).provider
    end

    should "say an HRIS level needs a field" do
      patch tenant_org_graph_settings_level_provider_path(@tribe_id), params: { provider: "hibob" }

      assert_equal "Tribe did not change: name the HRIS field this level's units are read from", flash[:alert]
    end

    should "preview the units a field would make, and offer to use it" do
      Hris::BaseAdapter.stub(:for, @adapter) do
        get tenant_org_graph_settings_level_field_path(@tribe_id, field_id: TEAM.id)
      end

      frame = "turbo-frame#org-graph-field-level-#{@tribe_id}"
      assert_select "#{frame} label", text: "HRIS field for Tribe"
      assert_select "#{frame} h3", text: "Team as the level"
      assert_select "#{frame} li", text: /Payments\s*1 person/
      assert_select "#{frame} form[data-turbo-frame=_top] input[name=field][value='#{TEAM.id}']"
    end

    should "show each level with its source and units, and a picker only for an empty one" do
      Hris::BaseAdapter.stub(:for, @adapter) { get tenant_org_graph_settings_path }

      assert_select "#org-graph-level-#{@tribe_id}", text: /From Espalia · 0 units/
      assert_select "#org-graph-level-#{@tribe_id} turbo-frame#org-graph-field-level-#{@tribe_id}"
      assert_select "#org-graph-level-#{@squad_id}", text: /changes hands through the handover/
      assert_select "#org-graph-level-#{@squad_id} turbo-frame", count: 0
    end

    should "not find a level that isn't in the taxonomy" do
      get tenant_org_graph_settings_level_field_path(SecureRandom.uuid_v7)

      assert_response :not_found
    end
  end

  context "as a member" do
    setup { sign_in @member_user }

    should "not change a level's source" do
      patch tenant_org_graph_settings_level_provider_path(@tribe_id), params: { provider: "hibob", field: TEAM.id }

      assert_redirected_to root_path
      assert_equal "espalia", level(@tribe_id).provider
    end
  end
end
