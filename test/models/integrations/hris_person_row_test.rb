# frozen_string_literal: true

require "test_helper"

class Integrations::HrisPersonRowTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @person = ActsAsTenant.with_tenant(@tenant) do
      create(:person, tenant: @tenant, job_title: "Software Engineer", status: "active", hris_source: "hibob")
    end
    @mapping = HrisRoleMapping.new(
      hris_titles: [ "Software Engineer" ],
      framework_role_code: "E",
      level_ordinal: 3
    )
    @role = build_stubbed(:framework_role, role_id: SecureRandom.uuid_v7, code: "E")
    @level = build_stubbed(:framework_level, role_id: @role.role_id, level_id: SecureRandom.uuid_v7, ordinal: 3)
  end

  context "#status" do
    should "return :inactive for inactive person" do
      @person.status = "inactive"
      row = build_row(person: @person)
      assert_equal :inactive, row.status
      assert_equal "Inactive", row.status_label
      assert_equal :default, row.status_variant
    end

    should "return :no_title when person has no job title" do
      @person.job_title = nil
      row = build_row(person: @person)
      assert_equal :no_title, row.status
      assert_equal "No job title", row.status_label
    end

    should "return :unmapped when no mapping matches the title" do
      row = build_row(mapping: nil)
      assert_equal :unmapped, row.status
      assert_equal :warning, row.status_variant
    end

    should "return :missing_role when mapping exists but role is nil" do
      row = build_row(mapping: @mapping, role: nil)
      assert_equal :missing_role, row.status
    end

    should "return :missing_ordinal when neither mapping nor person has an ordinal" do
      mapping = HrisRoleMapping.new(hris_titles: [ "Engineer" ], framework_role_code: "E")
      @person.hris_level_ordinal = nil
      row = build_row(mapping: mapping, role: @role, level: nil)
      assert_equal :missing_ordinal, row.status
    end

    should "return :missing_level when ordinal is set but no level row exists" do
      row = build_row(mapping: @mapping, role: @role, level: nil)
      assert_equal :missing_level, row.status
    end

    should "return :pending_sync when fully resolves but no assignment yet" do
      row = build_row(mapping: @mapping, role: @role, level: @level, assignment: nil)
      assert_equal :pending_sync, row.status
      assert_equal :info, row.status_variant
    end

    should "return :assigned when assignment matches resolved role and level" do
      assignment = build_assignment(role_id: @role.role_id, level_id: @level.level_id)
      row = build_row(mapping: @mapping, role: @role, level: @level, assignment: assignment)
      assert_equal :assigned, row.status
      assert_equal :success, row.status_variant
      assert_equal "Assigned", row.status_label
    end

    should "return :drift when existing assignment differs from resolved target" do
      stale_role_id = SecureRandom.uuid_v7
      assignment = build_assignment(role_id: stale_role_id, level_id: @level.level_id)
      row = build_row(mapping: @mapping, role: @role, level: @level, assignment: assignment)
      assert_equal :drift, row.status
      assert_equal :warning, row.status_variant
    end
  end

  context "#mapped_role_code" do
    should "return mapping code when mapping is present" do
      row = build_row(mapping: @mapping)
      assert_equal "E", row.mapped_role_code
    end

    should "return em-dash when mapping is nil" do
      row = build_row(mapping: nil)
      assert_equal "\u2014", row.mapped_role_code
    end
  end

  context "#resolved_ordinal" do
    should "return mapping ordinal when set" do
      row = build_row(mapping: @mapping)
      assert_equal 3, row.resolved_ordinal
    end

    should "fall back to person.hris_level_ordinal when mapping has none" do
      mapping = HrisRoleMapping.new(hris_titles: [ "x" ], framework_role_code: "E")
      @person.hris_level_ordinal = 5
      row = build_row(mapping: mapping)
      assert_equal 5, row.resolved_ordinal
    end

    should "return nil when neither mapping nor person has an ordinal" do
      mapping = HrisRoleMapping.new(hris_titles: [ "x" ], framework_role_code: "E")
      @person.hris_level_ordinal = nil
      row = build_row(mapping: mapping)
      assert_nil row.resolved_ordinal
    end
  end

  context "#assigned_label" do
    should "return em-dash when no assignment" do
      row = build_row
      assert_equal "\u2014", row.assigned_label
    end

    should "format role code and level ordinal when assigned" do
      assignment = build_assignment(role_id: @role.role_id, level_id: @level.level_id)
      row = build_row(mapping: @mapping, role: @role, level: @level, assignment: assignment)
      assert_equal "E L3", row.assigned_label
    end
  end

  private

  def build_row(person: @person, mapping: nil, role: nil, level: nil, assignment: nil)
    Integrations::HrisPersonRow.new(
      person: person,
      mapping: mapping,
      role: role,
      level: level,
      assignment: assignment
    )
  end

  # Builds a stub assignment whose `.role` and `.level` mimic the eager-loaded
  # PersonFrameworkAssignment without going through ActiveRecord.
  def build_assignment(role_id:, level_id:)
    Struct.new(:role_id, :level_id, :role, :level).new(
      role_id,
      level_id,
      @role,
      @level
    )
  end
end
