# frozen_string_literal: true

require "test_helper"

class Tenant::HrisFieldPreviewsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TEAM = Hris::Field.new(id: "work.customColumns.column_team", name: "Team", kind: :list)
  FRAME = "turbo-frame##{Views::Integrations::HrisFieldPreviewFrame::FRAME_ID}".freeze

  FakeAdapter = Struct.new(:values, :error) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = [ TEAM ]
    def read_field(_field_id, kind:, alongside: nil) = error ? raise(error) : values
  end

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      %w[hb-1 hb-2 hb-3].each { create(:person, tenant: @tenant, hris_source: "hibob", external_id: it) }
    end
    @adapter = FakeAdapter.new(
      { "hb-1" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments"),
        "hb-2" => Hris::FieldValue.new(state: :value, id: "8", label: "Platform"),
        "hb-3" => Hris::FieldValue.withheld }
    )
  end

  def get_preview(adapter: @adapter, frame: true, target: "level", field_id: TEAM.id)
    headers = frame ? { "Turbo-Frame" => Views::Integrations::HrisFieldPreviewFrame::FRAME_ID } : {}
    Hris::BaseAdapter.stub(:for, adapter) do
      get tenant_hris_field_preview_path(field_id:, target:), headers:
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show the units a level field would make, in the frame alone for a frame request" do
      get_preview

      assert_response :success
      assert_select FRAME do
        assert_select "h3", text: "Team as the level"
        assert_select "li", count: 2
        assert_select "li", text: /Payments\s*1 person/
      end
      assert_select "h1", count: 0
    end

    should "count a fact's values" do
      get_preview(target: "cost_centre")

      assert_select "#{FRAME} h3", text: "Team as the cost centre"
      assert_select "#{FRAME} dd", text: "2", minimum: 1
      assert_select "#{FRAME} li", count: 0
    end

    should "wrap the frame in a page for a plain visit" do
      get_preview(frame: false)

      assert_select "h1", text: "Preview an HRIS field"
      assert_select "#{FRAME} h3", text: "Team as the level"
    end

    should "say why for a field the HRIS does not have" do
      get_preview(field_id: "work.nothing")

      assert_response :success
      assert_select "#{FRAME} p[role=status]", text: /no field work.nothing/
    end

    should "say why for a target the preview does not know" do
      get_preview(target: "name")

      assert_select "#{FRAME} p[role=status]", text: /target must be one of/
    end

    should "say the HRIS refused the credentials" do
      get_preview(adapter: FakeAdapter.new(nil, Hris::Hibob::Errors::AuthenticationError.new("no")))

      assert_select "#{FRAME} p[role=status]", text: "The HRIS refused the stored credentials."
    end

    should "say the HRIS did not answer, for any other failure" do
      get_preview(adapter: FakeAdapter.new(nil, Hris::Hibob::Errors::ApiError.new(status: 503, body: "down")))

      assert_select "#{FRAME} p[role=status]", text: /did not answer as expected/
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "be refused on a visit" do
      get_preview(frame: false)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "be refused in the frame, without the HRIS being read" do
      get_preview(adapter: FakeAdapter.new(nil, RuntimeError.new("the HRIS was read")))

      assert_select FRAME, text: /don't have access/
      assert_select "h3", count: 0
    end
  end
end
