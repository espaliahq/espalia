# frozen_string_literal: true

require "test_helper"

class Hris::Hibob::ResponseMapperTest < ActiveSupport::TestCase
  setup do
    @fixture = JSON.parse(
      File.read(Rails.root.join("test/fixtures/files/hibob/people_search_response.json"))
    )
  end

  context "#call" do
    should "map a complete employee to Person attributes" do
      employee = @fixture["employees"][0]
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_equal "bob-001", result[:external_id]
      assert_equal "alice@example.com", result[:email]
      assert_equal "Alice Smith", result[:name]
      assert_equal "Software Engineer", result[:job_title]
      assert_equal "Engineering", result[:department]
      assert_equal "hibob", result[:hris_source]
      assert_equal "active", result[:status]
      assert_equal employee, result[:hris_raw_data]
    end

    should "mark inactive employees" do
      employee = @fixture["employees"][2]
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_equal "inactive", result[:status]
    end

    should "downcase and strip email" do
      employee = { "id" => "1", "email" => "  Alice@Example.COM  ", "firstName" => "A", "surname" => "B", "isActive" => true }
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_equal "alice@example.com", result[:email]
    end

    should "build name from firstName + surname when displayName is absent" do
      employee = { "id" => "1", "email" => "a@b.com", "firstName" => "Jane", "surname" => "Doe", "isActive" => true }
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_equal "Jane Doe", result[:name]
    end

    should "use displayName when present" do
      employee = { "id" => "1", "email" => "a@b.com", "displayName" => "Dr. Jane", "firstName" => "Jane", "surname" => "Doe", "isActive" => true }
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_equal "Dr. Jane", result[:name]
    end

    should "handle missing optional work fields" do
      employee = { "id" => "1", "email" => "a@b.com", "firstName" => "Test", "surname" => "User", "isActive" => true }
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_nil result[:job_title]
      assert_nil result[:department]
    end

    should "default to active when isActive is not false" do
      employee = { "id" => "1", "email" => "a@b.com", "firstName" => "A", "surname" => "B", "isActive" => true }
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_equal "active", result[:status]
    end

    should "extract hris_level_ordinal from humanReadable custom column when configured" do
      employee = @fixture["employees"][0]
      result = Hris::Hibob::ResponseMapper.call(employee, level_field_id: "column_test_id")

      assert_equal 5, result[:hris_level_ordinal]
    end

    should "skip hris_level_ordinal when level_field_id is nil" do
      employee = @fixture["employees"][0]
      result = Hris::Hibob::ResponseMapper.call(employee)

      assert_nil result[:hris_level_ordinal]
    end

    should "return nil ordinal when custom column value is missing" do
      employee = { "id" => "1", "email" => "a@b.com", "firstName" => "A", "surname" => "B", "isActive" => true }
      result = Hris::Hibob::ResponseMapper.call(employee, level_field_id: "column_missing")

      assert_nil result[:hris_level_ordinal]
    end

    should "return nil ordinal when value is not a valid integer string" do
      employee = {
        "id" => "1", "email" => "a@b.com", "firstName" => "A", "surname" => "B", "isActive" => true,
        "humanReadable" => { "work" => { "customColumns" => { "column_test_id" => "-" } } }
      }
      result = Hris::Hibob::ResponseMapper.call(employee, level_field_id: "column_test_id")

      assert_nil result[:hris_level_ordinal]
    end
  end

  context "#level_label" do
    should "read the level as HiBob shows it, even when it is no ordinal" do
      employee = { "humanReadable" => { "work" => { "customColumns" => { "column_test_id" => " Senior " } } } }

      assert_equal "Senior", Hris::Hibob::ResponseMapper.new(employee, level_field_id: "column_test_id").level_label
    end

    should "be nil without a level column or a value" do
      assert_nil Hris::Hibob::ResponseMapper.new(@fixture["employees"].first).level_label
      assert_nil Hris::Hibob::ResponseMapper.new({}, level_field_id: "column_test_id").level_label
    end
  end

  context "#manager_external_id" do
    should "extract manager ID from reportsTo object" do
      employee = @fixture["employees"][0]
      mapper = Hris::Hibob::ResponseMapper.new(employee)

      assert_equal "bob-002", mapper.manager_external_id
    end

    should "return nil when reportsTo is null" do
      employee = @fixture["employees"][1]
      mapper = Hris::Hibob::ResponseMapper.new(employee)

      assert_nil mapper.manager_external_id
    end

    should "return nil when work section is absent" do
      employee = { "id" => "1", "email" => "a@b.com", "firstName" => "A", "surname" => "B" }
      mapper = Hris::Hibob::ResponseMapper.new(employee)

      assert_nil mapper.manager_external_id
    end
  end

  context "#org_graph_facts" do
    should "read site, FTE, employment type and dates from a fixture employee" do
      facts = Hris::Hibob::ResponseMapper.new(@fixture["employees"][0]).org_graph_facts

      assert_equal({ site: "Melbourne", country: nil, fte: 1.0, employment_type: "Permanent", started_on: "2023-01-15" }, facts)
    end

    should "read the termination date" do
      assert_equal "2026-10-31", Hris::Hibob::ResponseMapper.new(@fixture["employees"][2]).org_graph_facts[:terminated_on]
    end

    should "turn a part-time percentage into a fraction and keep HiBob's own type label" do
      employee = { "payroll" => { "employment" => { "fte" => 80, "type" => "77" } },
                   "humanReadable" => { "payroll" => { "employment" => { "type" => " Fixed term (casual) " } } } }

      facts = Hris::Hibob::ResponseMapper.new(employee).org_graph_facts

      assert_in_delta 0.8, facts[:fte]
      assert_equal "Fixed term (casual)", facts[:employment_type]
    end

    should "record a field HiBob sends blank as absent" do
      employee = { "work" => { "site" => "", "startDate" => nil }, "payroll" => { "employment" => { "fte" => nil, "type" => "" } } }

      assert_equal({ site: nil, country: nil, fte: nil, employment_type: nil, started_on: nil },
        Hris::Hibob::ResponseMapper.new(employee).org_graph_facts)
    end

    should "leave out a field HiBob does not send, so it is never compared" do
      assert_empty Hris::Hibob::ResponseMapper.new({ "id" => "1", "work" => { "title" => "Engineer" } }).org_graph_facts
    end

    should "hold nothing the Org Graph can't take: an FTE outside 1–100, a date that isn't ISO 8601, a type with no label" do
      employee = { "work" => { "startDate" => "15/01/2023" }, "internal" => { "terminationDate" => "soon" },
                   "payroll" => { "employment" => { "fte" => 120, "type" => "4411" } } }

      assert_equal({ fte: nil, employment_type: nil, started_on: nil, terminated_on: nil },
        Hris::Hibob::ResponseMapper.new(employee).org_graph_facts)
      assert_nil Hris::Hibob::ResponseMapper.new({ "payroll" => { "employment" => { "fte" => 0 } } }).org_graph_facts[:fte]
    end

    should "read the flat payload shape" do
      employee = { "/work/site" => { "value" => "Sydney" }, "/payroll/employment/fte" => { "value" => 50 },
                   "/work/startDate" => { "value" => "2024-02-01" } }

      assert_equal({ site: "Sydney", country: nil, fte: 0.5, employment_type: nil, started_on: "2024-02-01" },
        Hris::Hibob::ResponseMapper.new(employee).org_graph_facts)
    end
  end

  context "#list_values" do
    should "pair the stored id with the label from a nested payload" do
      employee = {
        "id" => "1",
        "work" => { "department" => "209192163", "title" => 4417, "customColumns" => { "column_level" => "88" } },
        "humanReadable" => {
          "work" => { "department" => "Platform", "title" => "Software Engineer", "customColumns" => { "column_level" => "5" } }
        }
      }
      values = Hris::Hibob::ResponseMapper.new(employee, level_field_id: "column_level").list_values

      assert_equal Hris::Hibob::ResponseMapper::ListValue.new(id: "209192163", label: "Platform"), values[:department]
      assert_equal Hris::Hibob::ResponseMapper::ListValue.new(id: "4417", label: "Software Engineer"), values[:job_title]
      assert_equal Hris::Hibob::ResponseMapper::ListValue.new(id: "88", label: "5"), values[:level]
    end

    should "read the id from the flat payload shape" do
      employee = {
        "id" => "1",
        "/work/department" => { "value" => "209192163" },
        "/work/customColumns/column_level" => { "value" => "88" },
        "humanReadable" => { "work" => { "department" => "Platform" } }
      }
      values = Hris::Hibob::ResponseMapper.new(employee, level_field_id: "column_level").list_values

      assert_equal Hris::Hibob::ResponseMapper::ListValue.new(id: "209192163", label: "Platform"), values[:department]
      assert_equal Hris::Hibob::ResponseMapper::ListValue.new(id: "88", label: nil), values[:level]
    end

    should "read a flat value given as a bare id" do
      employee = { "id" => "1", "/work/department" => "209192163" }

      assert_equal "209192163", Hris::Hibob::ResponseMapper.new(employee).list_values[:department].id
    end

    should "keep a legacy item whose id is its own name" do
      employee = { "id" => "1", "work" => { "department" => "Engineering" }, "humanReadable" => { "work" => { "department" => "Engineering" } } }

      assert_equal "Engineering", Hris::Hibob::ResponseMapper.new(employee).list_values[:department].id
    end

    should "leave out a blank field, and the level when no level column is configured" do
      employee = {
        "id" => "1",
        "work" => { "department" => "", "title" => nil, "customColumns" => { "column_level" => "88" } }
      }

      assert_empty Hris::Hibob::ResponseMapper.new(employee).list_values
    end

    should "leave the mapped attributes unchanged" do
      employee = @fixture["employees"][0]

      assert_equal Hris::Hibob::ResponseMapper.call(employee).keys,
        %i[external_id email name job_title department hris_source status hris_raw_data]
    end
  end
end
