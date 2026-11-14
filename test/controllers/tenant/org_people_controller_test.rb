# frozen_string_literal: true

require "test_helper"

# The person drawer (#132): Tenant::OrgPeopleController and
# OrgPersonMembershipsController.
class Tenant::OrgPeopleControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                                    person: create(:person, tenant: @tenant, name: "Gil Ostrom"))
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  def membership(person, key)
    ActsAsTenant.with_tenant(@tenant) { OrgMembership.find_by(person_id: @org[person].id, unit_id: @org[key]) }
  end

  def drawer = Nokogiri::HTML5(response.body).at_css("aside#org-graph-drawer")

  # Engineering is HiBob's, so HiBob may place people in it, once it knows them.
  def place_in_engineering_from_hibob(person)
    ActsAsTenant.with_tenant(@tenant) do
      @org[person].update_columns(hris_source: "hibob", external_id: "hb-#{person}")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .set_membership(@org[person].id, @org[:engineering], provider: "hibob", effective_on: "2026-01-05")
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "with a window picked" do
      setup { @window = { from: "2026-02-01", to: Date.current.iso8601, by: "learned" } }

      should "keep the Units view compared behind the drawer, and the window when closing it" do
        get tenant_org_person_path(@org[:brook], unit: @org[:checkout], **@window)

        assert_includes Nokogiri::HTML5(response.body).at_css("#org-graph-comparison").text, "What changed"
        assert_equal tenant_org_graph_path(unit: @org[:checkout], **@window), drawer.at_css("a[aria-label='Close']")["href"]

        get tenant_org_person_path(@org[:brook], unit: @org[:checkout], back: "edit", **@window)
        assert_equal edit_tenant_org_unit_path(@org[:checkout], **@window), drawer.at_css("a[aria-label='Close']")["href"]
      end

      should "carry the window through a change and back to the drawer" do
        get tenant_org_person_path(@org[:ezra], unit: @org[:platform], **@window)
        drawer.css("form[method='post']").each do |form|
          assert_equal @window.values, %w[from to by].map { form.at_css("input[name='#{it}']")&.[]("value") }, form["action"]
        end

        post tenant_org_person_memberships_path(@org[:ezra]), params: { unit_id: @org[:payments], unit: @org[:platform], **@window }

        assert_redirected_to tenant_org_person_path(@org[:ezra], unit: @org[:platform], **@window)
      end
    end

    should "open a person's drawer over the unit they were opened from" do
      get tenant_org_person_path(@org[:brook], unit: @org[:checkout])

      assert_response :success
      assert_equal "Checkout", Nokogiri::HTML5(response.body).at_css("#org-graph-unit").text
      assert_equal "Brook Tamsin", drawer.at_css("#org-graph-drawer-title").text
      assert_equal tenant_org_graph_path(unit: @org[:checkout]), drawer.at_css("a[aria-label='Close']")["href"]
      checkout = drawer.at_css("#org-person-team-#{@org[:checkout]}")
      assert_includes checkout.text, "Tech lead · 50%"
      assert_equal [ tenant_org_person_membership_path(@org[:brook], @org[:checkout]) ] * 2,
                   checkout.css("form").map { |form| form["action"] }
      assert_includes drawer.css("#org-person-join option").map(&:text).map(&:strip), "Payments"
      assert_not_includes drawer.css("#org-person-join option").map(&:text).map(&:strip), "Checkout"
      assert_includes drawer.text, "Joined Checkout as Tech lead at 50%"
      assert_equal Date.current.iso8601, drawer.at_css("input[name='effective_on']")["value"]
    end

    should "close back to the unit drawer it was opened from, after a change too" do
      get tenant_org_person_path(@org[:brook], unit: @org[:checkout], back: "edit")
      assert_equal edit_tenant_org_unit_path(@org[:checkout]), drawer.at_css("a[aria-label='Close']")["href"]

      delete tenant_org_person_membership_path(@org[:brook], @org[:platform]), params: { unit: @org[:checkout], back: "edit" }
      assert_redirected_to tenant_org_person_path(@org[:brook], unit: @org[:checkout], back: "edit")
    end

    should "start from today when the date in the address isn't one" do
      get tenant_org_person_path(@org[:brook], on: "garbage")

      assert_equal Date.current.iso8601, drawer.at_css("input##{Views::Tenant::OrgGraph::PersonDrawer::DATE_ID}")["value"]
    end

    should "open someone in no team over the unit they were opened beside" do
      get tenant_org_graph_path(unit: @org[:payments])

      assert_equal tenant_org_person_path(@org[:ezra], unit: @org[:payments]),
                   Nokogiri::HTML5(response.body).at_css("#in-no-team a")["href"]
    end

    should "show an HRIS membership read-only, naming its provider" do
      place_in_engineering_from_hibob(:ada)

      get tenant_org_person_path(@org[:ada])

      engineering = drawer.at_css("#org-person-team-#{@org[:engineering]}")
      assert_includes engineering.text, "From HiBob"
      assert_includes engineering.text, "Change it in HiBob."
      assert_empty engineering.css("form")
      assert_equal 2, drawer.at_css("#org-person-team-#{@org[:platform]}").css("form").size
    end

    should "open a forgotten person as a former member, with history" do
      ActsAsTenant.with_tenant(@tenant) { @org[:dot].update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

      get tenant_org_person_path(@org[:dot])

      assert_equal Person::FORMER_MEMBER, drawer.at_css("#org-graph-drawer-title").text
      assert_includes drawer.text, "Joined Payments at 100%"
      assert_empty drawer.css("form")
      assert_not_includes response.body, "Dot Fennick"
    end

    should "add a team with a role and an allocation given as a percentage, from the chosen date" do
      post tenant_org_person_memberships_path(@org[:ezra]),
           params: { unit_id: @org[:platform], role: "Analyst", allocation: "40", effective_on: "2026-11-02", unit: @org[:platform] }

      assert_redirected_to tenant_org_person_path(@org[:ezra], on: "2026-11-02", unit: @org[:platform])
      added = membership(:ezra, :platform)
      assert_equal [ "Analyst", 0.4, Date.new(2026, 11, 2) ], [ added.role, added.allocation, added.member_since ]
    end

    should "ask for a team when none is chosen" do
      post tenant_org_person_memberships_path(@org[:ezra]), params: { unit_id: "" }

      follow_redirect!
      assert_equal "Choose a team to add Ezra Pell to.", drawer.at_css("#org-person-alert").text.strip
    end

    should "move a team and end one" do
      patch tenant_org_person_membership_path(@org[:brook], @org[:platform]), params: { unit_id: @org[:payments] }
      assert_redirected_to tenant_org_person_path(@org[:brook])
      assert_nil membership(:brook, :platform)
      assert membership(:brook, :payments)

      delete tenant_org_person_membership_path(@org[:brook], @org[:checkout])
      assert_response :see_other
      assert_nil membership(:brook, :checkout)
    end

    should "bring a refusal back to the drawer and leave the person unchanged" do
      place_in_engineering_from_hibob(:ada)

      delete tenant_org_person_membership_path(@org[:ada], @org[:engineering])

      follow_redirect!
      assert_match(/\AHiBob supplies/, drawer.at_css("#org-person-alert").text.strip)
      assert membership(:ada, :engineering)
    end

    should "say who may make a change the command refuses" do
      refusal = OrgGraph::Authorization::Refused.new("Only a tenant admin, an Org Graph editor or Ada's manager can change Ada's teams")
      Operations::OrgGraph::RemoveMember.stub(:call, ->(**) { raise refusal }) do
        delete tenant_org_person_membership_path(@org[:ada], @org[:platform])
      end

      follow_redirect!
      assert_equal refusal.message, drawer.at_css("#org-person-alert").text.strip
      assert membership(:ada, :platform)
    end

    should "send an unknown person back to the Units view" do
      get tenant_org_person_path(SecureRandom.uuid_v7)

      assert_redirected_to tenant_org_graph_path
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "not open the drawer" do
      get tenant_org_person_path(@org[:ada])

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "not change anyone's teams" do
      post tenant_org_person_memberships_path(@org[:ezra]), params: { unit_id: @org[:platform] }
      delete tenant_org_person_membership_path(@org[:ada], @org[:platform])

      assert_nil membership(:ezra, :platform)
      assert membership(:ada, :platform)
    end
  end
end
