# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show the unit tree, the opened unit's sub-units and the people in no team" do
      org = build_org_graph(@tenant)

      get tenant_org_graph_path

      assert_response :success
      page = Nokogiri::HTML5(response.body)
      assert_equal %w[Engineering Checkout Payments Platform],
                   page.css("nav[aria-labelledby='org-graph-tree-label'] a[href*='unit=']").map { |a| a.at_css("span span").text }
      assert_equal "Engineering", page.at_css("#org-graph-unit").text
      assert page.at_css("#unit-#{org[:platform]}")
      assert_includes page.at_css("#in-no-team").text, "Ezra Pell"
      assert_not_includes response.body, "Faye Lumen"
    end

    should "open the unit named in the query" do
      org = build_org_graph(@tenant)

      get tenant_org_graph_path(unit: org[:checkout])

      assert_equal "Checkout", Nokogiri::HTML5(response.body).at_css("#org-graph-unit").text
      assert_select "a[aria-current='page']", text: /Checkout/
    end

    should "count only the direct members on the opened unit's own card" do
      org = build_org_graph(@tenant)
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_membership(org[:ezra].id, org[:engineering], **OrgGraphFixture::PROVENANCE)
      end

      get tenant_org_graph_path

      page = Nokogiri::HTML5(response.body)
      assert_includes page.at_css("#unit-#{org[:engineering]}").text, "1 directly"
      assert_includes page.at_css("#unit-#{org[:checkout]}").text, "3 people"
    end

    should "name the provider of a unit the HRIS holds, and only of that one" do
      org = build_org_graph(@tenant)

      get tenant_org_graph_path
      assert_includes response.body, "From HiBob, read-only"

      get tenant_org_graph_path(unit: org[:platform])
      assert_not_includes response.body, "read-only"
    end

    should "say so when the tenant has no units" do
      get tenant_org_graph_path

      assert_response :success
      assert_includes response.body, "No units yet"
    end

    should "mark what changed since a date, and keep the window in the tree's links" do
      travel_to Time.zone.parse("2026-01-05 09:00")
      org = build_org_graph(@tenant)
      travel_to Time.zone.parse("2026-03-01 09:00")
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .rename_unit(org[:platform], "Core Platform", effective_on: "2026-02-10")
      end

      get tenant_org_graph_path(from: "2026-02-01")

      page = Nokogiri::HTML5(response.body)
      assert_includes page.at_css("#unit-#{org[:platform]}").text, "was Platform"
      assert_includes page.at_css("#org-graph-comparison").text, "What changed: since 1 Feb"
      assert page.css("nav[aria-labelledby='org-graph-tree-label'] a[href*='unit=']").all? { it["href"].include?("from=2026-02-01") }
      assert_equal [ "2026-02-28", "2026-03-01" ], page.css("#comparison-from, #comparison-to").map { it["max"] }
    end

    should "refuse a reversed range with a message, and mark nothing" do
      build_org_graph(@tenant)

      get tenant_org_graph_path(from: "2026-02-10", to: "2026-02-01")

      assert_response :success
      page = Nokogiri::HTML5(response.body)
      assert_includes page.at_css("#org-graph-comparison [role='status'], #org-graph-comparison [role='alert']").text,
                      "Pick an end date after the date you compare with."
      assert_not page.css("nav[aria-labelledby='org-graph-tree-label'] a").any? { it["href"].include?("from=") }
    end
  end

  context "as a non-admin member" do
    setup { sign_in @member_user }

    should "redirect away from the Org Graph, with or without a date" do
      get tenant_org_graph_path(from: "2026-02-01")

      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end
end
