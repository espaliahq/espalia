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
                   page.css("nav[aria-labelledby='org-graph-tree-label'] a[href*='unit=']").map { |a| a.at_css("span").text }
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

    should "sum up what is beneath the opened unit in taxonomy order, whatever the tree order" do
      org = build_org_graph(@tenant)
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .create_unit(SecureRandom.uuid_v7, "Atlas", level_id: org[:squad],
                                                      parent_id: org[:engineering], effective_on: "2026-01-01")
      end

      get tenant_org_graph_path

      assert_includes response.body, "4 people, 2 teams, 2 squads"
    end

    should "warn about the people in no team only while someone is in it" do
      org = build_org_graph(@tenant)
      tray_link = "nav[aria-labelledby='org-graph-tree-label'] a[href='#in-no-team']"

      get tenant_org_graph_path
      page = Nokogiri::HTML5(response.body)
      assert_includes page.at_css(tray_link)["class"].split, "text-warning"
      assert_includes page.at_css("#in-no-team")["class"].split, "border-warning"
      assert_includes page.at_css("#in-no-team-heading")["class"].split, "text-warning"

      ActsAsTenant.with_tenant(@tenant) do
        handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        Person.active.in_no_unit.each do |person|
          handler.record_person(person.id, **OrgGraphFixture::PROVENANCE, employment_status: "employed") unless org.value?(person)
          handler.set_membership(person.id, org[:platform], **OrgGraphFixture::PROVENANCE)
        end
      end
      get tenant_org_graph_path
      page = Nokogiri::HTML5(response.body)
      assert_not_includes page.at_css(tray_link)["class"].split, "text-warning"
      assert_not_includes page.at_css("#in-no-team")["class"].split, "border-warning"
      assert_not_includes page.at_css("#in-no-team-heading")["class"].split, "text-warning"
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

    should "show the opened unit's activity beside it" do
      org = build_org_graph(@tenant)

      get tenant_org_graph_path(unit: org[:platform])

      sidebar = Nokogiri::HTML5(response.body).at_css("##{Views::Tenant::OrgGraph::Sidebar::ID}")
      assert_equal "Activity", sidebar.at_css("h2").text
      assert_includes sidebar.text, "Added Ada Quill"
    end

    should "change an entry back, and return to the unit with a notice" do
      org = build_org_graph(@tenant)
      entry = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_unit(org[:platform]).first }

      post change_back_tenant_org_graph_path, params: { entry_id: entry.id, unit: org[:platform] }

      assert_redirected_to tenant_org_graph_path(unit: org[:platform])
      assert_equal "Changed back.", flash[:notice]
      assert entry.reload.changed_back?
    end

    should "change a group back by its cause" do
      org = build_org_graph(@tenant)
      entry = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_unit(org[:checkout]).first }

      post change_back_tenant_org_graph_path, params: { cause_id: entry.cause_id, unit: org[:checkout] }

      assert entry.reload.changed_back?
    end

    should "return to the page of activity the change was made from" do
      org = build_org_graph(@tenant)
      entry = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_unit(org[:platform]).first }

      post change_back_tenant_org_graph_path, params: { entry_id: entry.id, unit: org[:platform], activity_page: "2" }

      assert_redirected_to tenant_org_graph_path(unit: org[:platform], activity_page: "2")
    end

    should "return to the unit with the reason when a change can't be changed back" do
      org = build_org_graph(@tenant)
      created = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_unit(org[:platform]).last }

      post change_back_tenant_org_graph_path, params: { entry_id: created.id, unit: org[:platform] }

      assert_redirected_to tenant_org_graph_path(unit: org[:platform])
      assert_equal "Unit Created can't be changed back", flash[:alert]
    end

    should "say so when the tenant has no units" do
      get tenant_org_graph_path

      assert_response :success
      assert_includes response.body, "No units yet"
    end
  end

  context "as a non-admin member" do
    setup { sign_in @member_user }

    should "redirect away from the Org Graph" do
      get tenant_org_graph_path

      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "refuse to change anything back" do
      org = build_org_graph(@tenant)
      entry = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_unit(org[:platform]).first }

      post change_back_tenant_org_graph_path, params: { entry_id: entry.id, unit: org[:platform] }

      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_not entry.reload.changed_back?
    end
  end
end
