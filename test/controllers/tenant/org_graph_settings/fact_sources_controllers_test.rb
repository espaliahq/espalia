# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphSettings::FactSourcesControllersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  CENTRE = Hris::Field.new(id: "work.customColumns.column_centre", name: "Cost centre code", kind: :text)
  FRAME = "turbo-frame#org-graph-field-cost_centre"

  FakeAdapter = Struct.new(:error) do
    include Hris::FieldRows

    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = error ? raise(error) : [ CENTRE ]
    def read_field(_field_id, kind:, alongside: nil) = { "hb-1" => Hris::FieldValue.new(state: :value, id: nil, label: "CC-7") }
  end

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-1")
    end
  end

  def provider_of(fact) = ActsAsTenant.with_tenant(@tenant) { OrgFactProvider.find_by(fact:) }

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "give a fact to the HRIS and back to Espalia" do
      patch tenant_org_graph_settings_fact_provider_path("cost_centre"), params: { provider: "hibob" }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Cost centre now comes from HiBob.", flash[:notice]
      assert_equal "hibob", provider_of("cost_centre").provider

      patch tenant_org_graph_settings_fact_provider_path("cost_centre"), params: { provider: "espalia" }
      assert_equal "Cost centre now comes from Espalia.", flash[:notice]
    end

    should "read a fact from the field chosen" do
      patch tenant_org_graph_settings_fact_provider_path("cost_centre"),
            params: { provider: "hibob", fields: { cost_centre: CENTRE.id } }

      assert_equal "Cost centre now comes from the HiBob field you chose.", flash[:notice]
      assert_equal({ "cost_centre" => CENTRE.id }, provider_of("cost_centre").fields)
    end

    should "say why a provider this server doesn't know was refused" do
      patch tenant_org_graph_settings_fact_provider_path("title"), params: { provider: "workday" }

      assert_match(/\ATitle did not change: /, flash[:alert])
    end

    should "list the HRIS's fields for a mappable fact" do
      Hris::BaseAdapter.stub(:for, FakeAdapter.new) { get tenant_org_graph_settings_fact_field_path("cost_centre") }

      assert_response :success
      assert_select "#{FRAME} select[name=field_id] option", text: "Cost centre code"
      assert_select "#{FRAME} #org-graph-field-use-cost_centre", count: 0
    end

    should "preview a field before it is chosen, and offer to choose it" do
      Hris::BaseAdapter.stub(:for, FakeAdapter.new) do
        get tenant_org_graph_settings_fact_field_path("cost_centre", field_id: CENTRE.id)
      end

      assert_select "#{FRAME} h3", text: "Cost centre code as the cost centre"
      assert_select "#{FRAME} form[data-turbo-frame=_top] input[name='fields[cost_centre]'][value='#{CENTRE.id}']"
      assert_select "#org-graph-field-use-cost_centre", text: "Use this field"
    end

    should "say plainly when the HRIS can't list its fields" do
      Hris::BaseAdapter.stub(:for, FakeAdapter.new(Hris::Hibob::Errors::AuthenticationError.new("no"))) do
        get tenant_org_graph_settings_fact_field_path("cost_centre")
      end

      assert_select FRAME, text: "The HRIS refused the stored credentials."
    end

    should "not offer a field picker for a fact no field can be chosen for" do
      get tenant_org_graph_settings_fact_field_path("title")

      assert_response :not_found
    end
  end

  context "as an Org Graph editor" do
    should "be turned away from a preview, as the HRIS's values are for admins" do
      editor = create(:user)
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: editor, role: :member, org_graph_editor: true) }
      sign_in editor

      Hris::BaseAdapter.stub(:for, FakeAdapter.new) do
        get tenant_org_graph_settings_fact_field_path("cost_centre"), params: { field_id: CENTRE.id }
      end

      assert_redirected_to root_path
    end
  end

  context "as a member" do
    setup { sign_in @member_user }

    should "not change a fact's source" do
      patch tenant_org_graph_settings_fact_provider_path("title"), params: { provider: "hibob" }

      assert_redirected_to root_path
      assert_nil provider_of("title")
    end

    should "not list the HRIS's fields" do
      get tenant_org_graph_settings_fact_field_path("cost_centre")

      assert_redirected_to root_path
    end
  end
end
