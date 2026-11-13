# frozen_string_literal: true

require "test_helper"

class Tenant::HrisLevelFieldsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  FIELDS = [
    Hris::Field.new(id: "work.customColumns.column_2", name: "Level", kind: :text),
    Hris::Field.new(id: "work.department", name: "Department", kind: :list)
  ].freeze

  # Answers `field_catalogue` as an adapter would, or raises the given error.
  FakeAdapter = Struct.new(:fields, :error) do
    def field_catalogue = error ? raise(error) : fields
    def catalogue_id(field_id) = field_id
  end

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  def get_frame(adapter = FakeAdapter.new(FIELDS))
    Hris::BaseAdapter.stub(:for, adapter) { get tenant_hris_level_field_path }
  end

  def options = css_select("select#hris_connection_level_field_id option")

  def stub_catalogue(adapter)
    adapter.define_singleton_method(:field_catalogue) { FIELDS }
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "offer the HRIS's fields by name, marked list or text, after None" do
      @tenant.update_hris!(settings: { level_field_id: nil })

      get_frame

      assert_response :success
      assert_select "turbo-frame##{Views::Integrations::HrisLevelFieldFrame::FRAME_ID}"
      assert_equal [ "None", "Department · list", "Level · text" ], options.map(&:text)
      assert_equal [ "", "work.department", "work.customColumns.column_2" ], options.map { it["value"] }
    end

    should "select the stored field" do
      @tenant.update_hris!(settings: { level_field_id: "work.customColumns.column_2" })

      get_frame

      assert_equal "work.customColumns.column_2", options.find { it["selected"] }["value"]
    end

    should "keep a stored field the HRIS no longer lists, marked as missing and selected" do
      @tenant.update_hris!(settings: { level_field_id: "work.customColumns.column_gone" })

      get_frame

      kept = options.find { it["selected"] }
      assert_equal "work.customColumns.column_gone", kept["value"]
      assert_match "no longer in the HRIS", kept.text
    end

    should "select the value the page's form holds, which after a rejected save is the admin's choice" do
      Hris::BaseAdapter.stub(:for, FakeAdapter.new(FIELDS)) do
        get tenant_hris_level_field_path(current: "work.department")
      end

      assert_equal "work.department", options.find { it["selected"] }["value"]
    end

    should "match a level field stored as a bare column id to its field" do
      @tenant.update_hris!(settings: { level_field_id: "column_2" })

      Hris::BaseAdapter.stub(:for, Hris::Hibob::Adapter.new(@tenant).tap { stub_catalogue(it) }) { get tenant_hris_level_field_path }

      assert_equal "work.customColumns.column_2", options.find { it["selected"] }["value"]
      assert_no_match "no longer in the HRIS", response.body
    end

    should "keep the value and say so when reading the catalogue fails in any other way" do
      get_frame(FakeAdapter.new(nil, NoMethodError.new("undefined method for nil")))

      assert_response :success
      assert_select "input[type=hidden][name='hris_connection[level_field_id]'][value='work.customColumns.column_test_id']"
      assert_includes response.body, "did not answer as expected"
    end

    should "keep the stored value with the reason when the HRIS fails" do
      get_frame(FakeAdapter.new(nil, Hris::Hibob::Errors::ApiError.new(status: 503, body: "secret body")))

      assert_response :success
      assert_select "select", count: 0
      assert_select "input[type=hidden][name='hris_connection[level_field_id]'][value='work.customColumns.column_test_id']"
      assert_includes response.body, "did not answer as expected"
      assert_not_includes response.body, "secret body"
    end

    should "say when the HRIS refuses the credentials" do
      get_frame(FakeAdapter.new(nil, Hris::Hibob::Errors::AuthenticationError.new("Invalid HiBob credentials")))

      assert_includes response.body, "refused the stored credentials"
    end

    should "ask for credentials before reading the HRIS" do
      @tenant.disconnect_hris!

      get_frame(FakeAdapter.new(nil, RuntimeError.new("must not be called")))

      assert_includes css_select("p[role=status]").text, Views::Integrations::HrisLevelFieldFrame::NOT_CONNECTED
    end
  end

  context "as a tenant member" do
    should "be denied" do
      sign_in @member_user

      get_frame

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end
end
