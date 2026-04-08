# frozen_string_literal: true

require "test_helper"

class HrisRoleMappingTest < ActiveSupport::TestCase
  context "validations" do
    should "accept a valid mapping with level_ordinal" do
      mapping = HrisRoleMapping.new(
        hris_titles: [ "Senior Software Engineer" ],
        framework_role_code: "E",
        level_ordinal: 5
      )
      assert mapping.valid?
    end

    should "accept a valid mapping without level_ordinal" do
      mapping = HrisRoleMapping.new(
        hris_titles: [ "Engineering Manager" ],
        framework_role_code: "EM"
      )
      assert mapping.valid?
    end

    should "require framework_role_code" do
      mapping = HrisRoleMapping.new(hris_titles: [ "Foo" ])
      assert_not mapping.valid?
      assert_not_empty mapping.errors[:framework_role_code]
    end

    should "require at least one non-blank hris_title" do
      mapping = HrisRoleMapping.new(hris_titles: [], framework_role_code: "E")
      assert_not mapping.valid?
      assert_not_empty mapping.errors[:hris_titles]
    end

    should "reject all-blank hris_titles" do
      mapping = HrisRoleMapping.new(hris_titles: [ "", "   " ], framework_role_code: "E")
      assert_not mapping.valid?
      assert_not_empty mapping.errors[:hris_titles]
    end

    should "reject level_ordinal below 1" do
      mapping = HrisRoleMapping.new(hris_titles: [ "x" ], framework_role_code: "E", level_ordinal: 0)
      assert_not mapping.valid?
      assert_not_empty mapping.errors[:level_ordinal]
    end

    should "reject level_ordinal above 20" do
      mapping = HrisRoleMapping.new(hris_titles: [ "x" ], framework_role_code: "E", level_ordinal: 21)
      assert_not mapping.valid?
      assert_not_empty mapping.errors[:level_ordinal]
    end
  end

  context "#normalized_hris_titles" do
    should "downcase, strip, and drop blanks" do
      mapping = HrisRoleMapping.new(
        hris_titles: [ "  Senior Software Engineer  ", "STAFF ENGINEER", "" ],
        framework_role_code: "E"
      )
      assert_equal [ "senior software engineer", "staff engineer" ], mapping.normalized_hris_titles
    end
  end
end
