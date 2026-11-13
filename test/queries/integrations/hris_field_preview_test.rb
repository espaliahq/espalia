# frozen_string_literal: true

require "test_helper"

class Integrations::HrisFieldPreviewTest < ActiveSupport::TestCase
  PROVENANCE = { provider: "hibob", effective_on: "2026-11-01" }.freeze
  TEAM = Hris::Field.new(id: "work.customColumns.column_team", name: "Team", kind: :list)
  CENTRE = Hris::Field.new(id: "work.customColumns.column_cc", name: "Cost centre", kind: :text)

  # Answers the catalogue and the field read as an adapter would.
  FakeAdapter = Struct.new(:values, :fields, :asked_alongside) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = fields
    def read_field(_field_id, kind:, alongside: nil)
      self.asked_alongside = alongside
      values
    end
  end

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      .claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
    @people = %w[hb-1 hb-2 hb-3 hb-4 hb-5].index_with do |external_id|
      create(:person, tenant: @tenant, hris_source: "hibob", external_id:)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def value(label, id: nil) = Hris::FieldValue.new(state: :value, id:, label:)

  def preview(values, target:, field: TEAM)
    Integrations::HrisFieldPreview.new(@tenant, field_id: field.id, target:,
      adapter: FakeAdapter.new(values, [ TEAM, CENTRE ])).call
  end

  context "for a level" do
    should "count the units the field would make, the people in each, and those blank or withheld" do
      result = preview({ "hb-1" => value("Payments", id: "7"), "hb-2" => value("Payments", id: "7"),
                         "hb-3" => value("Growth", id: "9"), "hb-4" => Hris::FieldValue.blank,
                         "hb-5" => Hris::FieldValue.withheld }, target: "level")

      assert_equal [ [ "Payments", 2 ], [ "Growth", 1 ] ], result.units.map { [ it.label, it.people ] }
      assert_equal [ 5, 1, 1 ], [ result.people, result.blank, result.withheld ]
    end

    should "keep two list items that share a label as two units, as the mirror would" do
      result = preview({ "hb-1" => value("Sales", id: "1"), "hb-2" => value("Sales", id: "2") }, target: "level")

      assert_equal [ 1, 1 ], result.units.map(&:people)
    end

    should "count only the active people Espalia holds from that HRIS" do
      @people["hb-2"].update!(status: "inactive")
      create(:person, tenant: @tenant, hris_source: "bamboohr", external_id: "hb-9")

      result = preview({ "hb-1" => value("Payments", id: "7"), "hb-2" => value("Payments", id: "7"),
                         "hb-9" => value("Payments", id: "7"), "hb-404" => value("Payments", id: "7") }, target: "level")

      assert_equal 1, result.people
    end
  end

  context "for a fact" do
    setup do
      %w[hb-1 hb-2 hb-3].each do |external_id|
        @handler.record_person(@people[external_id].id, **PROVENANCE, employment_status: "employed", cost_centre: "Platform")
      end
    end

    should "count who has a value and who would change from what the graph holds" do
      result = preview({ "hb-1" => value("Platform"), "hb-2" => value("Payments"), "hb-3" => Hris::FieldValue.blank,
                         "hb-4" => value("Payments"), "hb-5" => Hris::FieldValue.withheld },
        target: "cost_centre", field: CENTRE)

      assert_equal [ 5, 3, 1, 1 ], [ result.people, result.with_value, result.blank, result.withheld ]
      assert_equal 3, result.would_change, "a new value, a value cleared and a first value change; a match does not"
    end

    should "read each person's stream in the tenant it was given, whatever tenant is current" do
      ActsAsTenant.current_tenant = nil

      result = preview({ "hb-1" => value("Platform"), "hb-2" => value("Payments") }, target: "cost_centre", field: CENTRE)

      assert_equal 1, result.would_change
    end

    should "never compare a withheld person, so their fact stands" do
      result = preview({ "hb-1" => Hris::FieldValue.withheld }, target: "cost_centre", field: CENTRE)

      assert_equal 0, result.would_change
    end

    should "ask for a country only beside the site it travels with, and a cost centre alone" do
      adapter = FakeAdapter.new({}, [ CENTRE ])
      Integrations::HrisFieldPreview.new(@tenant, field_id: CENTRE.id, target: "country", adapter:).call
      assert_equal "site", adapter.asked_alongside

      Integrations::HrisFieldPreview.new(@tenant, field_id: CENTRE.id, target: "cost_centre", adapter:).call
      assert_nil adapter.asked_alongside
    end

    should "write nothing" do
      assert_no_difference -> { Rails.configuration.event_store.read.count } do
        preview({ "hb-1" => value("Payments") }, target: "cost_centre", field: CENTRE)
      end
    end
  end

  should "refuse a field the catalogue does not hold" do
    assert_raises(Integrations::HrisFieldPreview::UnknownField) do
      Integrations::HrisFieldPreview.new(@tenant, field_id: "work.nothing", target: "level",
        adapter: FakeAdapter.new({}, [ TEAM ])).call
    end
  end

  should "refuse a target no field can be chosen for" do
    assert_raises(ArgumentError) do
      Integrations::HrisFieldPreview.new(@tenant, field_id: TEAM.id, target: "title", adapter: FakeAdapter.new({}, []))
    end
  end
end
