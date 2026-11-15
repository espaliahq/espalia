# frozen_string_literal: true

require "application_system_test_case"

class PlanPayUploadSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    level = SecureRandom.uuid_v7
    payments = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: (Date.current - 30).iso8601)
      structure.create_unit(payments, "Payments", level_id: level, effective_on: (Date.current - 30).iso8601)
      graph = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      [ [ "Ada Quill", "ada.quill@example.com" ], [ "Cy Quill", "cy.quill@example.com" ] ].each do |name, email|
        person = create(:person, tenant: @tenant, name:, email:)
        graph.record_person(person.id, **ESPALIA, effective_on: (Date.current - 30).iso8601, employment_status: "employed")
        graph.set_membership(person.id, payments, **ESPALIA, effective_on: (Date.current - 30).iso8601, allocation: 1.0)
      end
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: (Date.current + 1).iso8601)[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    end
  end

  teardown { FileUtils.rm_f(@files) if @files }

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "let a holder check a file of pay, fix it, and hold it" do
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id)
        click_link_with_js_fallback("Upload pay…", expect_text: "Upload actual pay")

        check_file("person,amount,currency,period\nada.quill@example.com,91234,EUR,year\nnobody@example.com,1,EUR,year\n",
                   expect_text: "1 line needs fixing")
        assert_text "Line 3 names no one in the organisation."
        assert_no_button "Hold pay for 1 person"
        assert_no_sideways_overflow

        check_file("person,amount,currency,period\nada.quill@example.com,91234,EUR,year\n", expect_text: "Hold pay for 1 person")
        assert_text "Every amount reads as full-time pay, in Today."
        assert_text "People on the map the file leaves out (1)"
        assert_no_text "91234"
        assert_no_sideways_overflow

        click_button_with_js_fallback("Hold pay for 1 person", expect_text: "Held actual pay for 1 person.")
        assert_current_path map_plan_path(@plan_id)
      end

      should "offer a member without the right no upload" do
        sign_in_as(@viewer.user)
        visit map_plan_path(@plan_id)
        assert_text "Read only."
        assert_no_link "Upload pay…"
      end
    end
  end

  private

  # The browser reads the file again when the confirm sends it, so it stays on disk until the test ends.
  def check_file(text, expect_text:)
    path = Rails.root.join("tmp", "pay-upload-#{SecureRandom.hex(4)}.csv")
    File.write(path, text)
    (@files ||= []) << path
    attach_file "CSV file", path
    js_set_checkbox "pay-upload-basis-full_time", checked: true
    click_button_with_js_fallback("Check the file", expect_text:)
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end
end
