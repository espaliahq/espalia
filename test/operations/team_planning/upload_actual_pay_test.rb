# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::UploadActualPayTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  HEADER = "person,amount,currency,period\n"

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @teams = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    ActsAsTenant.with_tenant(@tenant) do
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: @teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: @teams, effective_on: "2025-01-01")

      @ada = create(:person, tenant: @tenant, name: "Ada Quill", email: "ada.quill@example.com", external_id: "E-100")
      @cy = create(:person, tenant: @tenant, name: "Cy Quill", email: "cy.quill@example.com")
      @off_map = create(:person, tenant: @tenant, name: "Di Quill", email: "di.quill@example.com")
      [ @ada, @cy ].each do |person|
        people.record_person(person.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
        people.set_membership(person.id, @payments, **ESPALIA, allocation: 1.0)
      end
      create(:tenant_user, tenant: @tenant, person: @cy, user: create(:user, email: "cy.work@example.com"))

      PayBand.create!(level: e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "EUR")

      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-01-01")[:plan_id]
    @year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def upload(csv, as: @admin, basis: "full_time", scenario_id: @year, **params)
    call(Operations::TeamPlanning::UploadActualPay, as:, plan_id: @plan_id, scenario_id:, csv:, basis:, **params)
  end

  def preview_and_confirm(csv, basis: "full_time")
    signature = upload(csv, basis:).fetch(:signature)
    upload(csv, basis:, signature:)
  end

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  def seat(result, person) = result[:seats][:scenario].find { it[:seat_id] == person.id }

  def cost = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id: @year, unit_id: @payments)

  def event_count = Rails.configuration.event_store.read.count

  should "match people by id, HRIS id or either email, and preview what the file would change" do
    csv = "Amount,PERIOD,ignored,Person,Currency\n" \
          "90413,year,x,E-100,eur\n" \
          "7000,month,y,CY.WORK@example.com,EUR\n"
    preview = upload("\u{FEFF}#{csv}")

    assert_nil preview[:problem]
    assert_equal [ 2, [] ], preview.values_at(:rows_read, :failures)
    assert_equal [ @ada.id, @cy.id ], preview[:matched_ids]
    assert_equal [ @ada.id, @cy.id ], preview[:newly_priced_ids]
    assert_equal({ @ada.id => "Ada Quill", @cy.id => "Cy Quill" }, preview[:names])
    assert_match(/\A\h{64}\z/, preview[:signature])
    assert_no_pay_figure preview, "90413"

    by_id = upload("#{HEADER}#{@ada.id.upcase},90413,EUR,year\n#{@cy.email.upcase},1,EUR,year\n")
    assert_equal [ @ada.id, @cy.id ], by_id[:matched_ids]
  end

  should "count the people on the map the file leaves out, and the seats it would reprice" do
    preview_and_confirm("#{HEADER}E-100,90413,EUR,year\n")
    preview = upload("#{HEADER}E-100,95000,EUR,year\n")

    assert_equal [ @cy.id ], preview[:missing_ids]
    assert_equal [ [], [ @ada.id ], [] ], preview.values_at(:newly_priced_ids, :replaced_ids, :unchanged_ids)
    assert_equal({ @ada.id => "Ada Quill", @cy.id => "Cy Quill" }, preview[:names])
  end

  should "price a 0.8 FTE seat exactly as team_planning_set_actual_pay does, on each basis" do
    call(Operations::TeamPlanning::SetPlanValue, plan_id: @plan_id, scenario_id: @year, person_id: @ada.id, field: "fte", value: "0.8")

    %w[full_time actual].each do |basis|
      call(Operations::TeamPlanning::SetActualPay, plan_id: @plan_id, scenario_id: @year, person_id: @ada.id,
                                                   amount: "90413", currency: "EUR", period: "year", basis:)
      expected = cost
      call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @year, subject_id: @ada.id, facet: "data:pay")

      assert_equal 1, preview_and_confirm("#{HEADER}E-100,90413,EUR,year\n", basis:)[:written]
      assert_equal expected[:total], cost[:total], basis
      assert_equal seat(expected, @ada).slice(:base, :amount, :basis), seat(cost, @ada).slice(:base, :amount, :basis), basis
    end
  end

  should "give each bad row its line and codes only, and write nothing while any row is bad" do
    csv = HEADER +
          "E-100,90413,EUR,year\n" \
          "nobody@example.com,1,EUR,year\n" \
          "#{@off_map.id},2,EUR,year\n" \
          "ada.quill@example.com,3,EUR,year\n" \
          "#{@cy.id},-61937,XYZ,week\n" \
          "#{@cy.id},50,EUR,hour\n"
    before = event_count
    preview = upload(csv, basis: "actual")

    assert_equal [ { line: 3, codes: [ "no_match" ] }, { line: 4, codes: [ "not_on_map" ] },
                   { line: 5, codes: [ "duplicate_person" ] },
                   { line: 6, codes: %w[bad_amount bad_currency bad_period] },
                   { line: 7, codes: [ "duplicate_person", "hourly_actual" ] } ], preview[:failures]
    assert_nil preview[:signature]
    %w[90413 -61937 XYZ week nobody].each { assert_no_pay_figure preview, it }
    assert_equal before, event_count
  end

  should "number a bad row by the line its record starts on, though a quoted field spans lines" do
    csv = "#{HEADER}\"E-100\",90413,EUR,\"year\"\nnobody@example.com,1,EUR,\"year\nor so\"\nnobody@example.com,1,EUR,year\n"

    assert_equal [ 3, 5 ], upload(csv)[:failures].pluck(:line)
  end

  should "count a lone carriage return as a line ending" do
    assert_equal [ 2, 3 ], upload(HEADER.sub("\n", "\r") + "nobody@example.com,1,EUR,year\rnobody,1,EUR,year\r")[:failures].pluck(:line)
  end

  should "name the line a file stops reading as CSV, counting the lines a quoted field spans" do
    csv = "#{HEADER}nobody@example.com,1,EUR,\"year\nor so\"\n\"E-100\"x,1,EUR,year\n"

    assert_equal [ "bad_csv", 4 ], upload(csv).values_at(:problem, :line)
  end

  should "find the line ending outside quoted fields, and still refuse a stray one" do
    quoted_heading = "person,amount,currency,period,\"extra\nheading\"\r\nE-100,90413,EUR,year,x\r\n"
    stray = "person,amount,currency,period\r\nE-100,90413,EUR,ye\nar\r\n"

    assert_nil upload(quoted_heading)[:problem]
    assert_equal [ "bad_csv", 2 ], upload(stray).values_at(:problem, :line)
  end

    should "call an email two people share ambiguous" do
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, person: @off_map, user: create(:user, email: "shared@example.com"))
      @cy.update!(email: "Shared@example.com")
    end

    assert_equal [ { line: 2, codes: [ "ambiguous_match" ] } ], upload("#{HEADER}shared@example.com,1,EUR,year\n")[:failures]
  end

  should "name what is wrong with a file it can't read, never a line of it" do
    { "" => "empty", HEADER => "empty", "person,amount\nE-100,1\n" => "missing_column",
      "#{HEADER}\"E-100,90413\n" => "bad_csv", "#{HEADER}\xFF,1,EUR,year\n".b => "bad_encoding",
      HEADER + ("E-100,1,EUR,year\n" * 5_001) => "too_many_rows",
      "x" * (TeamPlanning::PayUpload::MAX_BYTES + 1) => "too_large" }.each do |csv, problem|
      preview = upload(csv)
      assert_equal problem, preview[:problem], problem
      assert_no_pay_figure preview, "90413"
      assert_nil preview[:signature]
    end
  end

  should "refuse a confirm whose file, basis or scenario changed by so much as a byte" do
    csv = "#{HEADER}E-100,90413,EUR,year\n"
    signature = upload(csv).fetch(:signature)
    changed = "The file, basis, scenario or the people it names changed since the preview"

    assert_equal changed, refusal { upload(csv.sub("90413", "90414"), signature:) }
    assert_equal changed, refusal { upload(csv, basis: "actual", signature:) }
    assert_equal changed, refusal { upload(csv, scenario_id: @plan_id, signature:) }
    assert_equal changed, refusal { upload(csv, signature: signature.reverse) }
    assert_equal 1, upload(csv, signature:)[:written]
  end

  should "judge a confirm by the plan's scope as it stands once the plan is locked" do
    csv = "#{HEADER}E-100,90413,EUR,year\n"
    signature = upload(csv).fetch(:signature)
    stale = TeamPlanningPlan.includes(:members).find(@plan_id)
    sales = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
                                       .create_unit(sales, "Sales", level_id: @teams, effective_on: "2025-01-01")
    end
    call(Operations::TeamPlanning::SetPlanScope, plan_id: @plan_id, unit_ids: [ sales ])
    before = event_count

    lookup = Object.new.tap { |it| it.define_singleton_method(:find_by) { |**| stale } }
    message = TeamPlanningPlan.stub(:includes, lookup) { refusal { upload(csv, signature:) } }

    assert_match "scenario changed", message
    assert_equal before, event_count
  end

  should "refuse a confirm once a line no longer names one person, and write nothing" do
    csv = "#{HEADER}cy.quill@example.com,90413,EUR,year\n"
    signature = upload(csv).fetch(:signature)
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, person: @off_map, user: create(:user, email: "cy.quill@example.com")) }

    before = event_count
    assert_equal "The scenario changed since the preview, so check the file again", refusal { upload(csv, signature:) }
    assert_equal before, event_count
  end

  should "refuse a confirm once a line names someone else, and write nothing" do
    csv = "#{HEADER}ada.quill@example.com,90413,EUR,year\n"
    signature = upload(csv).fetch(:signature)
    ActsAsTenant.with_tenant(@tenant) do
      @ada.update!(email: "ada.moved@example.com")
      @cy.update!(email: "ada.quill@example.com")
    end

    before = event_count
    assert_equal "The file, basis, scenario or the people it names changed since the preview", refusal { upload(csv, signature:) }
    assert_equal before, event_count
  end

  should "write once when the same signature is confirmed twice" do
    csv = "#{HEADER}E-100,90413,EUR,year\ncy.quill@example.com,80000,EUR,year\n"
    signature = upload(csv).fetch(:signature)

    assert_equal 2, upload(csv, signature:)[:written]
    before = event_count
    assert_equal 0, upload(csv, signature:)[:written]
    assert_equal before, event_count
  end

  should "write each row as one change noted as from an upload, sealing the amount away from every table" do
    preview_and_confirm("#{HEADER}E-100,91234.5678,EUR,year\n")
    entry = call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: @year)[:entries].find { it[:facet] == "data:pay" }

    assert_equal({ value: "From an upload" }, entry[:note])
    stored = [ ActiveRecord::Base.connection.select_values("SELECT data::text FROM event_store_events").join,
               *ActiveRecord::Base.connection.tables.grep(/\Ateam_planning/).map { ActiveRecord::Base.connection.select_values("SELECT t::text FROM #{it} t").join },
               ActiveRecord::Base.connection.select_values("SELECT t::text FROM mcp_pending_approvals t").join ].join
    assert_no_pay_figure stored, "91234.5678"
  end

  should "answer an editor without the see-pay right, a viewer and an outsider as if there were no plan" do
    csv = "#{HEADER}E-100,90413,EUR,year\n"
    signature = upload(csv).fetch(:signature)

    [ @editor, @viewer, @outsider ].each do |caller|
      assert_equal "No such plan", refusal { upload(csv, as: caller) }
      assert_equal "No such plan", refusal { upload(csv, as: caller, signature:) }
    end
  end

  should "stay off the MCP server while the privacy walk still sees it" do
    operation = Operations::TeamPlanning::UploadActualPay

    assert_not_includes Operations::Registry.tools, operation
    assert_includes Operations::Registry.all, operation
    assert_not Rails.root.join("test/mcp/tool_snapshots/#{Operations::Registry.tool_name_for(operation)}.json").exist?
  end
end
