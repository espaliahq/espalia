# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

class Operations::Integrations::HrisFieldPreviewTest < ActiveSupport::TestCase
  include HrisMappingFixtures

  TEAM = Hris::Field.new(id: "work.customColumns.column_team", name: "Team", kind: :list)

  FakeAdapter = Struct.new(:values, :fields) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = fields
    def read_field(_field_id, kind:, alongside: nil) = values
  end

  setup do
    build_hris_mapping_tenant
    ActsAsTenant.with_tenant(@tenant) do
      @people = %w[hb-1 hb-2 hb-3].map { create(:person, tenant: @tenant, hris_source: "hibob", external_id: it) }
    end
    @adapter = FakeAdapter.new(
      { "hb-1" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments"),
        "hb-2" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments"),
        "hb-3" => Hris::FieldValue.blank }, [ TEAM ]
    )
  end

  def call(tenant_user: @admin_tenant_user, **params)
    Hris::BaseAdapter.stub(:for, @adapter) do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Integrations::HrisFieldPreview.call(context: hris_context(tenant_user), params: params)
      end
    end
  end

  should "give a level's units and counts, and no person" do
    result = call(field_id: TEAM.id, target: "level")

    assert_equal({ field: { id: TEAM.id, name: "Team", kind: "list" }, target: "level", people: 3,
                   blank: 1, withheld: 0, units: [ { label: "Payments", people: 2 } ] }, result)
  end

  should "give a fact's counts" do
    result = call(field_id: TEAM.id, target: "cost_centre")

    assert_equal [ 3, 2, 1, 0, 2 ], result.values_at(:people, :with_value, :blank, :withheld, :would_change)
    assert_not result.key?(:units)
  end

  should "refuse a field the HRIS does not have" do
    assert_raises(Operations::Base::ParameterError) { call(field_id: "work.nothing", target: "level") }
  end

  should "refuse when no HRIS is connected" do
    @tenant.update!(hris_credentials: {})

    assert_raises(Operations::Base::ParameterError) { call(field_id: TEAM.id, target: "level") }
  end

  should "refuse a member who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @member_tenant_user, field_id: TEAM.id, target: "level") }
  end
end
