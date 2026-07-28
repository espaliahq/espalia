# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::ParticipantCandidatesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @dept_head = create(:person, tenant: @tenant, name: "Dana Dept", job_title: "Director")
    @em_1 = create(:person, tenant: @tenant, name: "Mia Manager", manager: @dept_head)
    @em_2 = create(:person, tenant: @tenant, name: "Raj Rater", manager: @dept_head)
    @ic = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em_1)
    create(:person, tenant: @tenant, name: "Omar IC", manager: @em_2)

    @other_head = create(:person, tenant: @tenant, name: "Kim Elsewhere")
    @other_em = create(:person, tenant: @tenant, name: "Miriam Otherteam", manager: @other_head)
    create(:person, tenant: @tenant, name: "Ref IC", manager: @other_em)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def query(viewer: @dept_head, admin: false)
    CalibrationSessions::ParticipantCandidates.new(viewer: viewer, admin: admin)
  end

  context "as a manager" do
    should "find managers within the subtree only" do
      names = query.search("mi").map { |e| e[:person].name }
      assert_includes names, "Mia Manager"
      assert_not_includes names, "Miriam Otherteam", "outside the viewer's subtree"
    end

    should "never return non-managers" do
      assert_empty query.search("Ivy")
    end

    should "include the viewer themselves (they manage people)" do
      assert_equal [ "Dana Dept" ], query.search("Dana").map { |e| e[:person].name }
    end

    should "match by email too" do
      assert_equal [ @em_1.name ], query.search(@em_1.email).map { |e| e[:person].name }
    end

    should "suggest the viewer's direct-report managers with report counts" do
      suggestions = query.suggestions
      assert_equal [ "Mia Manager", "Raj Rater" ], suggestions.map { |e| e[:person].name }
      assert_match(/1 report/, suggestions.first[:subtitle])
    end

    should "return nothing for a blank query" do
      assert_empty query.search("  ")
    end
  end

  context "as a tenant admin" do
    should "search managers across the whole org" do
      names = query(viewer: nil, admin: true).search("mi").map { |e| e[:person].name }
      assert_includes names, "Mia Manager"
      assert_includes names, "Miriam Otherteam"
    end

    should "offer no quick-add suggestions without a linked person (search-first)" do
      assert_empty query(viewer: nil, admin: true).suggestions
    end

    should "still suggest an admin's own direct-report managers" do
      names = query(viewer: @dept_head, admin: true).suggestions.map { |e| e[:person].name }
      assert_equal [ "Mia Manager", "Raj Rater" ], names
    end
  end
end
