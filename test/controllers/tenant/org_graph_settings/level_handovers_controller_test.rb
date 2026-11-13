# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphSettings::LevelHandoversControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  FakeAdapter = Struct.new(:values, :fields) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = fields
    def read_field(_field_id, kind:, alongside: nil) = values
  end

  TEAM = Hris::Field.new(id: "work.team", name: "Team", kind: :list,
                         values: [ Hris::Field::Value.new(id: "7", name: "Payments"), Hris::Field::Value.new(id: "8", name: "Search") ])

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      system = OrgGraph::Authorization::SYSTEM
      structure = OrgGraph::StructureCommandHandler.new(actor: system)
      @level_id = SecureRandom.uuid_v7
      structure.claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
      structure.define_taxonomy([ { level_id: @level_id, name: "Team" } ], effective_on: "2026-01-01")
      @payments, @legacy = %w[Payments Legacy].map do |name|
        SecureRandom.uuid_v7.tap { structure.create_unit(it, name, level_id: @level_id, effective_on: "2026-01-01") }
      end
      person = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-1")
      people = OrgGraph::CommandHandler.new(actor: system)
      people.record_person(person.id, provider: "hibob", effective_on: "2026-11-01", employment_status: "employed")
      people.set_membership(person.id, @payments, provider: "espalia", effective_on: "2026-11-01")
    end
    @adapter = FakeAdapter.new({ "hb-1" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments") }, [ TEAM ])
    @calls = { @payments => "match:7", @legacy => "retire" }
  end

  def level = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.find(@level_id) }

  def stubbed(&) = Hris::BaseAdapter.stub(:for, @adapter, &)

  def fingerprint
    stubbed { get tenant_org_graph_settings_level_handover_path(@level_id), params: { field_id: TEAM.id, calls: @calls } }
    css_select("input[name=fingerprint]").first["value"]
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "offer the HRIS fields, then suggest each unit's value by name" do
      stubbed { get tenant_org_graph_settings_level_handover_path(@level_id) }
      assert_select "select[name=field_id] option", text: "Team"

      stubbed { get tenant_org_graph_settings_level_handover_path(@level_id), params: { field_id: TEAM.id } }
      assert_select "select[name='calls[#{@payments}]'] option[selected]", text: /Payments/
      assert_select "select[name='calls[#{@legacy}]'] option[selected]", text: "Choose a call"
      assert_select "input[name=fingerprint]", count: 0
    end

    should "hold the switch back until every unit has a call" do
      stubbed do
        get tenant_org_graph_settings_level_handover_path(@level_id), params: { field_id: TEAM.id, calls: { @payments => "match:7" } }
      end

      assert_select "#org-graph-handover-summary-#{@level_id}", text: /Still to decide: Legacy/
      assert_select "#org-graph-hand-over-#{@level_id}", count: 0
    end

    should "hand the level over on the comparison's fingerprint, then hand it back" do
      seen = fingerprint
      stubbed do
        patch tenant_org_graph_settings_level_handover_path(@level_id),
              params: { field_id: TEAM.id, calls: @calls, fingerprint: seen }
      end

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Team now comes from HiBob, and its memberships follow the HRIS.", flash[:notice]
      assert_equal "hibob", level.provider

      get tenant_org_graph_settings_level_handover_path(@level_id)
      assert_select "p", text: /HiBob supplies Team: 1 unit and 1 membership/
      handback = css_select("input[name=fingerprint]").first["value"]

      delete tenant_org_graph_settings_level_handover_path(@level_id), params: { fingerprint: handback }
      assert_equal "Team now comes from Espalia. Its units and memberships stay as they are.", flash[:notice]
      assert_equal "espalia", level.provider
    end

    should "say why a stale comparison is refused" do
      stubbed do
        patch tenant_org_graph_settings_level_handover_path(@level_id),
              params: { field_id: TEAM.id, calls: @calls, fingerprint: "not-it" }
      end

      assert_match(/\ATeam was not handed over: The HRIS or the level has changed/, flash[:alert])
      assert_equal "espalia", level.provider
    end

    should "answer 404 for a level that doesn't exist" do
      get tenant_org_graph_settings_level_handover_path(SecureRandom.uuid_v7)
      assert_response :not_found
    end
  end

  context "as a member" do
    setup { sign_in @member_user }

    should "be refused" do
      stubbed { get tenant_org_graph_settings_level_handover_path(@level_id) }
      assert_redirected_to root_path
    end
  end
end
