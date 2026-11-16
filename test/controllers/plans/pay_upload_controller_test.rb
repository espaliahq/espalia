# frozen_string_literal: true

require "test_helper"

class Plans::PayUploadControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia" }.freeze
  CSV_TEXT = "person,amount,currency,period\nada.quill@example.com,91234.56,EUR,year\n"

  setup do
    @tenant = create(:tenant)
    level = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @second_editor = account(name: "Ed Second")
      @viewer = account(name: "Vic Viewer")
      @admin = account(role: :admin, name: "Ada Admin")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill", email: "ada.quill@example.com")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      graph = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      graph.record_person(@ada.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      graph.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-01-02", allocation: 1.0)
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @second_editor.person.id, role: "editor")
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    end
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end

  def file(text = CSV_TEXT) = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "pay.csv")

  def upload(intent: "preview", text: CSV_TEXT, **params)
    post pay_upload_plan_path(@plan_id), params: { scenario_id: @plan_id, basis: "full_time", file: file(text), intent:, **params }
  end

  def signature_from_preview
    upload
    Nokogiri::HTML5(response.body).at_css("input[name='signature']")["value"]
  end

  def held_pay? = pay_entries.positive?

  def pay_entries
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::History, @editor, plan_id: @plan_id, scenario_id: @plan_id)[:entries].count { it[:facet] == "data:pay" }
    end
  end

  context "an editor who holds the see-pay right" do
    setup { sign_in @editor.user }

    should "find the upload from the map, and see the form with no basis chosen" do
      get map_plan_path(@plan_id)
      assert_select "a[href='#{pay_upload_plan_path(@plan_id)}']", text: "Upload pay…"

      get pay_upload_plan_path(@plan_id)
      assert_response :success
      assert_select "form#pay-upload-form[enctype='multipart/form-data'][data-turbo-frame='pay-upload-preview']"
      assert_select "input[type='radio'][name='basis'][checked]", count: 0
      assert_select "turbo-frame#pay-upload-preview"
    end

    should "preview the counts and names, never the amount, then hold the pay and return to the map" do
      upload
      assert_response :success
      assert_select "[data-pay-upload-preview='ok']"
      assert_includes response.body, "Ada Quill"
      assert_includes response.body, "Hold pay for 1 person"
      assert_not_includes response.body, "91234.56"
      assert_not held_pay?

      signature = signature_from_preview
      upload(intent: "confirm", signature:)
      assert_redirected_to map_plan_path(@plan_id)
      assert_equal "Held actual pay for 1 person.", flash[:notice]
      assert_equal 1, pay_entries

      upload(intent: "confirm", signature:)
      assert_equal "Nothing to change: the plan already holds this pay.", flash[:notice]
      assert_equal 1, pay_entries
    end

    should "list each bad line by number and reason, with no signature to confirm" do
      upload(text: "person,amount,currency,period\nnobody@example.com,-619.37,EUR,year\n")
      assert_response :success
      assert_select "[data-pay-upload-line='2']", text: /Line 2 names no one in the organisation and has an amount/
      assert_select "input[name='signature']", count: 0
      assert_not_includes response.body, "nobody@example.com"
      assert_not_includes response.body, "619.37"
    end

    should "refuse a confirm for a file changed since the preview, and hold nothing" do
      signature = signature_from_preview
      upload(intent: "confirm", signature:, text: CSV_TEXT.sub("91234.56", "91235.56"))

      assert_response :unprocessable_content
      assert_select "turbo-frame#pay-upload-preview [role='alert']", text: /The file, basis, scenario or the people it names changed since the preview/
      assert_not_includes response.body, "91235.56"
      assert_not held_pay?
    end

    should "ask for a file and a basis before reading anything" do
      post pay_upload_plan_path(@plan_id), params: { scenario_id: @plan_id, basis: "full_time", intent: "preview" }
      assert_response :unprocessable_content
      assert_select "turbo-frame#pay-upload-preview [role='alert']", text: "Choose a file to upload."

      upload(basis: "")
      assert_response :unprocessable_content
      assert_includes response.body, "Say what the amounts are"
    end

    should "keep the file's text out of the log" do
      log = StringIO.new
      logger = ActiveSupport::Logger.new(log)
      original = Rails.logger
      ActionController::Base.logger = Rails.logger = logger
      upload
    ensure
      ActionController::Base.logger = Rails.logger = original
      assert_includes log.string, "[FILTERED]"
      assert_not_includes log.string, "91234.56"
      assert_not_includes log.string, "ada.quill@example.com"
    end
  end

  context "anyone else" do
    should "get the same 404 as someone outside the plan, for the page and both posts" do
      sign_in @editor.user
      signature = signature_from_preview
      sign_out @editor.user

      [ @second_editor, @viewer, @admin ].each do |caller|
        sign_in caller.user
        get map_plan_path(@plan_id)
        assert_select "a[href='#{pay_upload_plan_path(@plan_id)}']", count: 0 unless caller == @admin

        get pay_upload_plan_path(@plan_id)
        assert_response :not_found, caller.person.name
        upload
        assert_response :not_found, caller.person.name
        upload(intent: "confirm", signature:)
        assert_response :not_found, caller.person.name
        sign_out caller.user
      end
      assert_not held_pay?
    end
  end
end
