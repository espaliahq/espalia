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

    should "show each member's title, allocation and HRIS level, and the same for the people in no team" do
      org = build_org_graph(@tenant)

      get tenant_org_graph_path(unit: org[:payments])

      assert_select "#unit-#{org[:payments]}", text: /Engineer/
      assert_select "#unit-#{org[:payments]}", text: /100%/
      assert_select "#unit-#{org[:payments]}", text: /L4/
      assert_select "##{Views::Tenant::OrgGraph::Tray::ID}", text: /Analyst L3/
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

    should "show the organisation's activity in the sidebar of a tenant with no units yet" do
      ActsAsTenant.with_tenant(@tenant) do
        editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Brook Tamsin"))
        AccountGrants::CommandHandler.new.add(:org_graph_editor, editor)
      end

      get tenant_org_graph_path

      sidebar = Nokogiri::HTML5(response.body).at_css("##{Views::Tenant::OrgGraph::Sidebar::ID}")
      assert_equal "Organisation activity", sidebar.at_css("h2").text
      assert_includes sidebar.text, "Made Brook Tamsin an Org Graph editor"
      assert_includes sidebar.text, "Can't change back: #{OrgGraph::ChangeBackHandler::GRANT}"
    end

    should "name an account with no person in the organisation's activity" do
      ActsAsTenant.with_tenant(@tenant) do
        unlinked = create(:tenant_user, tenant: @tenant)
        AccountGrants::CommandHandler.new.add(:org_graph_editor, unlinked)
        AccountGrants::CommandHandler.new.remove(:org_graph_editor, tenant_user_id: unlinked.id, person_id: nil)
      end

      get tenant_org_graph_path

      sidebar = Nokogiri::HTML5(response.body).at_css("##{Views::Tenant::OrgGraph::Sidebar::ID}")
      assert_includes sidebar.text, "Made an account with no person an Org Graph editor"
      assert_includes sidebar.text, "An account with no person is no longer an Org Graph editor"
    end

    should "open the organisation's activity beside a unit, and link back to the unit's" do
      org = build_org_graph(@tenant)

      get tenant_org_graph_path(unit: org[:platform])
      sidebar = Nokogiri::HTML5(response.body).at_css("##{Views::Tenant::OrgGraph::Sidebar::ID}")
      assert_equal tenant_org_graph_path(unit: org[:platform], activity: "organisation"),
                   sidebar.at_css("a[href*='activity=organisation']")["href"]

      get tenant_org_graph_path(unit: org[:platform], activity: "organisation")
      sidebar = Nokogiri::HTML5(response.body).at_css("##{Views::Tenant::OrgGraph::Sidebar::ID}")
      assert_equal "Organisation activity", sidebar.at_css("h2").text
      assert_includes sidebar.text, "No activity yet"
      assert_includes sidebar.text, "Back to Platform's activity"
    end

    should "return to the organisation's activity when one of its changes can't be changed back" do
      org = build_org_graph(@tenant)
      entry = ActsAsTenant.with_tenant(@tenant) do
        editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
        AccountGrants::CommandHandler.new.add(:org_graph_editor, editor)
        OrgUnitActivity.for_organisation.last
      end

      post change_back_tenant_org_graph_path, params: { entry_id: entry.id, unit: org[:platform], activity: "organisation" }

      assert_redirected_to tenant_org_graph_path(unit: org[:platform], activity: "organisation")
      assert_equal OrgGraph::ChangeBackHandler::GRANT, flash[:alert].delete_prefix("Can't change back: ")
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

    should "refuse a reversed range with a message, mark nothing, and carry the dates as typed" do
      build_org_graph(@tenant)

      get tenant_org_graph_path(from: "2026-02-10", to: "2026-02-01")

      assert_response :success
      page = Nokogiri::HTML5(response.body)
      assert_includes page.at_css("#org-graph-comparison [role='status'], #org-graph-comparison [role='alert']").text,
                      "Pick an end date after the date you compare with."
      assert_not page.at_css("nav[aria-labelledby='org-graph-tree-label']").text.include?("was ")
      assert page.css("nav[aria-labelledby='org-graph-tree-label'] a[href*='unit=']").all? { it["href"].include?("from=2026-02-10&to=2026-02-01") },
             "the next page still shows why"
    end

    context "with a window picked" do
      setup do
        @org = build_org_graph(@tenant)
        @window = { from: "2026-02-01", by: "learned" }
      end

      should "keep the window when a change is changed back" do
        entry = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_unit(@org[:platform]).first }

        get tenant_org_graph_path(unit: @org[:platform], **@window)
        form = Nokogiri::HTML5(response.body).at_css("form[action='#{change_back_tenant_org_graph_path}']")
        assert_equal @window.values, @window.keys.map { form.at_css("input[name='#{it}']")["value"] }

        post change_back_tenant_org_graph_path, params: { entry_id: entry.id, unit: @org[:platform], **@window }

        assert_redirected_to tenant_org_graph_path(unit: @org[:platform], **@window)
      end

      should "keep the window when paging the activity" do
        get tenant_org_graph_path(unit: @org[:platform], activity_page: "2", **@window)

        newer = Nokogiri::HTML5(response.body).at_css("nav[aria-label='Activity pages'] a")
        assert_equal tenant_org_graph_path(unit: @org[:platform], activity_page: 1, **@window), newer["href"]
      end

      should "keep the window in the links to the unit drawer and a person's drawer" do
        get tenant_org_graph_path(unit: @org[:checkout], **@window)

        page = Nokogiri::HTML5(response.body)
        assert page.at_css("a[href='#{edit_tenant_org_unit_path(@org[:checkout], **@window)}']")
        assert page.at_css("a[href='#{tenant_org_person_path(@org[:brook], unit: @org[:checkout], **@window)}']")
      end
    end
  end

  context "as a non-admin member" do
    setup { sign_in @member_user }

    should "redirect away from the Org Graph, with or without a date" do
      get tenant_org_graph_path(from: "2026-02-01")

      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "refuse the organisation's activity, with no unit open or beside one" do
      org = build_org_graph(@tenant)
      ActsAsTenant.with_tenant(@tenant) do
        editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Rowan Grant"))
        AccountGrants::CommandHandler.new.add(:org_graph_editor, editor)
      end

      [ tenant_org_graph_path, tenant_org_graph_path(unit: org[:platform], activity: "organisation") ].each do |path|
        get path

        assert_response :redirect
        assert_equal "You are not authorized to perform this action.", flash[:alert]
        follow_redirect!
        assert_not_includes response.body, "Rowan Grant", path
      end
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

  context "as a unit owner who isn't an admin" do
    setup do
      @org = build_org_graph(@tenant)
      owner_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        owner = create(:person, tenant: @tenant, name: "Gale Orrin")
        create(:tenant_user, tenant: @tenant, user: owner_user, person: owner, role: :member)
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .add_unit_owner(@org[:payments], owner.id, effective_on: "2026-01-01")
        editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Rowan Grant"))
        AccountGrants::CommandHandler.new.add(:org_graph_editor, editor)
      end
      sign_in owner_user
    end

    should "show the units in the app's own layout, with no Settings and no way into a person" do
      get tenant_org_graph_path(unit: @org[:payments])

      assert_response :success
      assert_select "a[href='#{tenant_org_graph_path}']", text: "Organisation"
      assert_select "a", text: "Settings", count: 0
      assert_select "a[href^='#{tenant_org_person_path(@org[:dot])}']", count: 0
      assert_includes response.body, "Dot Fennick"
    end

    should "offer nothing to change back, and keep the organisation's activity to itself" do
      get tenant_org_graph_path(unit: @org[:payments], activity: "organisation")

      assert_response :success
      assert_select "button", text: /Change back/, count: 0
      assert_select "##{Views::Tenant::OrgGraph::Sidebar::ID}", text: /Rowan Grant/, count: 0
      assert_select "##{Views::Tenant::OrgGraph::Sidebar::ID}", text: /Added Dot Fennick/
    end

    should "show each member's name and role, but not their title, allocation or HRIS level" do
      get tenant_org_graph_path(unit: @org[:payments])

      assert_select "#unit-#{@org[:payments]}", text: /Dot Fennick/
      assert_select "#unit-#{@org[:payments]}", text: /Engineer|L4|100%/, count: 0
      assert_select "##{Views::Tenant::OrgGraph::Tray::ID}", text: /Ezra Pell/
      assert_select "##{Views::Tenant::OrgGraph::Tray::ID}", text: /Analyst|L3/, count: 0
    end

    should "refuse a person's drawer" do
      get tenant_org_person_path(@org[:dot], unit: @org[:payments])

      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end
end
