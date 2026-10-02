# frozen_string_literal: true

require "test_helper"
require "csv"

class Tenant::FeedbackExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cycle = create(:assessment_cycle,
        tenant: @tenant, name: "Q3 2026", framework_id: @framework_id, opened_at: 10.days.ago)
      @older_cycle = create(:assessment_cycle, :closed,
        tenant: @tenant, name: "Q2 2026", framework_id: @framework_id,
        opened_at: 100.days.ago, closed_at: 30.days.ago)
      @author = create(:person, tenant: @tenant, name: "Pat Peer")
      @recipient = create(:person, tenant: @tenant, name: "Fran First")
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @recipient.id, enrolled_at: 10.days.ago)
      create(:evidence_item, with_link: false,
        tenant: @tenant, author: @author, person_id: @recipient.id, framework_id: @framework_id,
        cycle_id: @cycle.cycle_id, content: "=HYPERLINK(\"https://evil.example\")",
        title: "Café → launch")
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "GET /tenant/feedback_exports/new" do
      should "pick the newest cycle and offer its months" do
        get new_tenant_feedback_export_path

        assert_response :success
        assert_select "select#feedback-export-cycle option[selected][value=?]", @cycle.cycle_id
        assert_select "form#feedback-export-download[action=?][data-turbo=false]",
          tenant_feedback_exports_path(format: :csv)
        assert_select "select#feedback-export-month option", text: "Whole cycle"
        assert_select "select#feedback-export-month option[value=?]", Time.current.strftime("%Y-%m")
      end

      should "show the chosen cycle" do
        get new_tenant_feedback_export_path(cycle_id: @older_cycle.cycle_id)

        assert_select "select#feedback-export-cycle option[selected][value=?]", @older_cycle.cycle_id
        assert_select "input[name=cycle_id][value=?]", @older_cycle.cycle_id
      end
    end

    context "GET /tenant/feedback_exports.csv" do
      should "download the cycle's feedback as a UTF-8 CSV" do
        get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id)

        assert_response :success
        assert_equal "text/csv; charset=utf-8", response.media_type + "; charset=" + response.charset
        assert_match(/\Aattachment; filename="growthos-feedback-export-q3-2026-all-\d{8}T\d{6}Z\.csv"/,
          response.headers["Content-Disposition"])

        assert_equal "no-store", response.headers["Cache-Control"]

        body = response.body.dup.force_encoding("UTF-8")
        assert body.start_with?("﻿")
        rows = CSV.parse(body.delete_prefix("﻿"))
        assert_equal Operations::Reporting::FeedbackExport::COLUMNS.values, rows.first
        assert_equal 2, rows.size
        record = rows.first.zip(rows.second).to_h
        assert_equal "Café → launch", record["Title"]
        assert_equal "Fran First", record["Recipient"]
      end

      should "neutralise feedback that a spreadsheet would run as a formula" do
        get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id)

        rows = CSV.parse(response.body.dup.force_encoding("UTF-8").delete_prefix("﻿"))
        record = rows.first.zip(rows.second).to_h
        assert_equal "'=HYPERLINK(\"https://evil.example\")", record["Feedback"]
      end

      should "treat the whole-cycle option's blank month as no month" do
        get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id, month: "")

        assert_response :success
      end

      should "name the month in the file" do
        month = Time.current.strftime("%Y-%m")
        get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id, month: month)

        assert_match(/-q3-2026-#{month}-/, response.headers["Content-Disposition"])
      end

      should "send the admin back to the picker for a month outside the cycle" do
        get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id, month: "2001-01")

        assert_redirected_to new_tenant_feedback_export_path(cycle_id: @cycle.cycle_id)
        assert_match(/outside the cycle's lifespan/, flash[:alert])
      end

      should "send the admin back to the picker for an unknown cycle" do
        get tenant_feedback_exports_path(format: :csv, cycle_id: SecureRandom.uuid_v7)

        assert_match(/that cycle doesn't exist/, flash[:alert])
      end

      should "send a request with no cycle back to the picker" do
        get tenant_feedback_exports_path(format: :csv)

        assert_redirected_to new_tenant_feedback_export_path
        assert_equal "Choose a cycle to export.", flash[:alert]
      end

      should "send an HTML request to the picker" do
        get tenant_feedback_exports_path(cycle_id: @cycle.cycle_id)

        assert_redirected_to new_tenant_feedback_export_path(cycle_id: @cycle.cycle_id)
      end
    end

    should "refuse the export while viewing as another user" do
      post impersonation_path, params: { tenant_user_id: @member_tu.id }
      get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "as a non-admin member" do
    setup { sign_in @member_user }

    should "redirect from the picker" do
      get new_tenant_feedback_export_path

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "redirect from the download" do
      get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "as a manager with reports in the cycle" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        manager = @member_tu.ensure_person!
        @recipient.update!(manager: manager)
      end
      sign_in @member_user
    end

    should "redirect from the download" do
      get tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id)

      assert_redirected_to root_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
