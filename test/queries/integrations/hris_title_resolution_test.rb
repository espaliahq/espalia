# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

class Integrations::HrisTitleResolutionTest < ActiveSupport::TestCase
  include HrisMappingFixtures

  setup do
    build_hris_mapping_tenant
    @resolution = Integrations::HrisTitleResolution.new(@tenant)
  end

  def titles = ActsAsTenant.with_tenant(@tenant) { @resolution.titles }

  should "list unmapped titles first" do
    assert_equal [ "Analytics Lead", "Engineering Manager (EM3)", "Software Engineer" ], titles.map(&:title)
    assert_equal [ true, true, false ], titles.map(&:unmapped?)
  end

  should "flag a holder the sync leaves on an assignment an earlier title gave them" do
    renamed = titles.find { |entry| entry.title == "Engineering Manager (EM3)" }

    assert_equal [ @renamed.id ], renamed.attention_rows.map { |row| row.person.id }
    assert renamed.attention_rows.first.stale_assignment?
    assert_equal "E L3", renamed.attention_rows.first.assigned_label
  end

  should "leave a settled title with nobody needing attention" do
    settled = titles.find { |entry| entry.title == "Software Engineer" }

    assert_empty settled.attention_rows
    assert_equal [ 3 ], settled.hris_levels
  end

  should "leave out inactive people" do
    ActsAsTenant.with_tenant(@tenant) { @unmapped.update!(status: "inactive") }

    assert_not_includes titles.map(&:title), "Analytics Lead"
  end

  should "offer each role's levels as mapping targets" do
    levels = ActsAsTenant.with_tenant(@tenant) { @resolution.level_ordinals_by_role_code }

    assert_equal({ "AE" => [ 2, 3 ], "E" => [ 3 ], "EM" => [ 3, 4 ] }, levels)
  end

  should "resolve one title's holders without matching titles that merely contain it" do
    ActsAsTenant.with_tenant(@tenant) do
      hris_person("Pat Senior", "Senior Software Engineer", assigned_to: [ @e_role, @e3 ])
      entry = @resolution.title("  software ENGINEER ")

      assert_equal "Software Engineer", entry.title
      assert_equal [ "Sam Settled" ], entry.rows.map { |row| row.person.name }
      assert_nil @resolution.title("Chief Vibes Officer")
    end
  end
end
