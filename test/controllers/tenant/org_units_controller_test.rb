# frozen_string_literal: true

require "test_helper"

# The unit drawer (#124): Tenant::OrgUnitsController, OrgUnitOwnersController
# and OrgUnitMembersController.
class Tenant::OrgUnitsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  def unit(key) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[key]) }

  def membership(person, key)
    ActsAsTenant.with_tenant(@tenant) { OrgMembership.find_by(person_id: @org[person].id, unit_id: @org[key]) }
  end

  # What OrgGraph::Authorization says when reach refuses a write.
  REFUSAL = /\AOnly a tenant admin|\AYou can change|\AYou need the right/

  def drawer = Nokogiri::HTML5(response.body).at_css("aside#org-graph-drawer")

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "with a unit the HRIS sync left out of a structure" do
      setup do
        ActsAsTenant.with_tenant(@tenant) do
          create(:hris_sync_issue, tenant: @tenant, unit_id: @org[:payments], parent_id: @org[:checkout],
                                   structure_unit_id: @org[:engineering])
        end
      end

      should "say why in that unit's drawer, with a link to the HRIS page" do
        get edit_tenant_org_unit_path(@org[:payments])

        section = drawer.at_css("#org-unit-sync-issues")
        assert_includes section.text, "under Checkout, inside Engineering's own structure"
        assert section.at_css("a[href='#{tenant_integration_path('hris', anchor: 'sync-issues')}']")
      end

      should "say nothing of it in another unit's drawer" do
        get edit_tenant_org_unit_path(@org[:checkout])

        assert_nil drawer.at_css("#org-unit-sync-issues")
      end

      should "say nothing of it to a viewer who may open the drawer but not the HRIS page" do
        IntegrationsPolicy.alias_method :real_show?, :show?
        IntegrationsPolicy.define_method(:show?) { false }
        get edit_tenant_org_unit_path(@org[:payments])

        assert_nil drawer.at_css("#org-unit-sync-issues")
      ensure
        IntegrationsPolicy.alias_method :show?, :real_show?
        IntegrationsPolicy.remove_method :real_show?
      end
    end

    context "with a window picked" do
      setup { @window = { from: "2026-02-01", by: "learned" } }

      should "keep the Units view compared behind the drawer, and the window in its links and forms" do
        get edit_tenant_org_unit_path(@org[:checkout], **@window)

        page = Nokogiri::HTML5(response.body)
        assert_includes page.at_css("#org-graph-comparison").text, "What changed"
        assert_equal tenant_org_graph_path(unit: @org[:checkout], **@window), drawer.at_css("a[aria-label='Close']")["href"]
        assert drawer.at_css("a[href='#{tenant_org_person_path(@org[:brook], unit: @org[:checkout], back: "edit", **@window)}']")
        drawer.css("form[method='post']").each do |form|
          assert_equal @window.values, @window.keys.map { form.at_css("input[name='#{it}']")&.[]("value") }, form["action"]
        end
      end

      should "keep the window when the unit is gone" do
        get edit_tenant_org_unit_path(SecureRandom.uuid, **@window)

        assert_redirected_to tenant_org_graph_path(**@window)
      end

      should "come back to the drawer with the window after a change" do
        patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" }, **@window }

        assert_redirected_to edit_tenant_org_unit_path(@org[:platform], **@window)
      end
    end

    should "open a unit's drawer over the Units view, with its details, owners and members" do
      get edit_tenant_org_unit_path(@org[:checkout])

      assert_response :success
      assert_equal "Checkout", Nokogiri::HTML5(response.body).at_css("#org-graph-unit").text
      assert_equal "Checkout", drawer.at_css("#org-graph-drawer-title").text
      assert_equal "Checkout", drawer.at_css("input#org-unit-name")["value"]
      assert_equal @org[:engineering], drawer.at_css("select#org-unit-parent option[selected]")["value"]
      parents = drawer.css("select#org-unit-parent option").map(&:text).map(&:strip)
      assert_not_includes parents, "Payments", "a unit can't move beneath its own sub-unit"
      brook = drawer.at_css("#org-unit-member-#{@org[:brook].id}")
      assert_includes brook.text, "Tech lead · 50%"
      assert_equal [ tenant_org_unit_member_path(@org[:checkout], @org[:brook].id) ] * 2,
                   brook.css("form").map { |form| form["action"] }, "a member's forms name the person by id"
      assert_equal Date.current.iso8601, drawer.at_css("input[name='effective_on']")["value"]
      assert_includes drawer.text, "No one owns this unit yet."
    end

    should "offer as parents only the units a level above" do
      get edit_tenant_org_unit_path(@org[:platform])

      assert_equal [ "None (at the top)", "Engineering" ],
                   drawer.css("select#org-unit-parent option").map(&:text).map(&:strip)
      assert_not drawer.at_css("select#org-unit-parent").key?("required"), "None (at the top) stays a choice"
    end

    should "show an HRIS unit's name and parent as read-only, naming the provider" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                .set_membership(@org[:ada].id, @org[:engineering], provider: "hibob", effective_on: "2026-01-05")
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                .set_membership(@org[:ezra].id, @org[:engineering], provider: "espalia", effective_on: "2026-01-05")
      end

      get edit_tenant_org_unit_path(@org[:engineering])

      assert_nil drawer.at_css("input#org-unit-name")
      assert_nil drawer.at_css("select#org-unit-parent")
      assert_includes drawer.text, "From HiBob: change its name and parent there."
      hris_row = drawer.at_css("#org-unit-member-#{@org[:ada].id}")
      assert_includes hris_row.text, "From HiBob"
      assert_nil hris_row.at_css("form")
      assert drawer.at_css("#org-unit-member-#{@org[:ezra].id} button[aria-label='Remove Ezra Pell from Engineering']")
      assert drawer.at_css("form[action='#{tenant_org_unit_owners_path(@org[:engineering])}']"), "owners stay editable"
    end

    should "send a retired unit back to the Units view" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .retire_unit(@org[:payments], effective_on: "2026-02-01")
      end

      get edit_tenant_org_unit_path(@org[:payments])

      assert_redirected_to tenant_org_graph_path
      assert_equal "That unit isn't in the Org Graph.", flash[:alert]
    end

    should "rename a unit from the chosen date and keep that date for the next change" do
      patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" }, effective_on: "2026-11-01" }

      assert_redirected_to edit_tenant_org_unit_path(@org[:platform], on: "2026-11-01")
      assert_equal "Core", unit(:platform).name
      follow_redirect!
      assert_equal "2026-11-01", drawer.at_css("input#org-unit-effective-on")["value"]
    end

    should "keep UTC's date for the next change when the tenant is already a day ahead" do
      @tenant.update!(time_zone: "Australia/Sydney")
      travel_to Time.utc(2026, 11, 18, 20) do
        patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" }, effective_on: "2026-11-18" }

        assert_redirected_to edit_tenant_org_unit_path(@org[:platform], on: "2026-11-18")
      end
    end

    should "move a unit to the root when no parent is chosen" do
      patch tenant_org_unit_path(@org[:payments]), params: { org_unit: { parent_id: "" } }

      assert_redirected_to edit_tenant_org_unit_path(@org[:payments])
      assert_nil unit(:payments).parent_id
    end

    context "changing a unit's type" do
      should "offer only the types that fit where the unit sits and above its sub-units" do
        get edit_tenant_org_unit_path(@org[:platform])
        assert_equal %w[Team Squad], drawer.css("select#org-unit-type option").map(&:text)

        get edit_tenant_org_unit_path(@org[:checkout])
        assert_nil drawer.at_css("select#org-unit-type")
        assert_includes drawer.text, "Unit type"
      end

      should "change it from the chosen date" do
        patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { level_id: @org[:squad] }, effective_on: "2026-02-01" }

        assert_redirected_to edit_tenant_org_unit_path(@org[:platform], on: "2026-02-01")
        assert_equal "Type changed.", flash[:notice]
        assert_equal @org[:squad], unit(:platform).level_id
      end

      should "bring a refusal back to the drawer and change nothing" do
        patch tenant_org_unit_path(@org[:checkout]), params: { org_unit: { level_id: @org[:squad] } }

        follow_redirect!
        assert_equal "Checkout can't change to Squad, as these wouldn't fit: Payments (Squad) under Checkout",
                     drawer.at_css("#org-unit-alert").text.strip
        assert_equal @org[:team], unit(:checkout).level_id
      end
    end

    should "bring a guard's refusal back to the drawer and change nothing" do
      patch tenant_org_unit_path(@org[:engineering]), params: { org_unit: { name: "Eng" } }

      assert_redirected_to edit_tenant_org_unit_path(@org[:engineering])
      assert_equal "Engineering", unit(:engineering).name
      follow_redirect!
      assert_equal "HiBob supplies this unit; change it there", drawer.at_css("#org-unit-alert").text.strip
    end

    should "say who may make a change the command refuses" do
      refusal = OrgGraph::Authorization::Refused.new("Only a tenant admin, an Org Graph editor or an owner of Platform can change Platform")
      Operations::OrgGraph::RenameUnit.stub(:call, ->(**) { raise refusal }) do
        patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" } }
      end

      follow_redirect!
      assert_equal refusal.message, drawer.at_css("#org-unit-alert").text.strip
      assert_equal "Platform", unit(:platform).name
    end

    should "add and remove owners" do
      post tenant_org_unit_owners_path(@org[:platform]), params: { person_ids: [ @org[:ada].id, @org[:ezra].id ] }
      assert_redirected_to edit_tenant_org_unit_path(@org[:platform])
      assert_equal [ "Ada Quill", "Ezra Pell" ], unit(:platform).own_owners.order(:name).map(&:name)

      delete tenant_org_unit_owner_path(@org[:platform], @org[:ezra].id)
      assert_response :see_other
      assert_equal [ "Ada Quill" ], unit(:platform).own_owners.map(&:name)
    end

    should "ask for someone when no owner is chosen" do
      post tenant_org_unit_owners_path(@org[:platform])

      follow_redirect!
      assert_equal "Choose someone to own Platform.", drawer.at_css("#org-unit-alert").text.strip
    end

    should "add a member with a role and an allocation given as a percentage" do
      post tenant_org_unit_members_path(@org[:payments]),
           params: { person_ids: [ @org[:ezra].id ], role: "Analyst", allocation: "40" }

      assert_redirected_to edit_tenant_org_unit_path(@org[:payments])
      added = membership(:ezra, :payments)
      assert_equal "Analyst", added.role
      assert_in_delta 0.4, added.allocation
    end

    should "say how many were added when one of several is refused" do
      post tenant_org_unit_members_path(@org[:platform]), params: { person_ids: [ @org[:ezra].id, @org[:ada].id ] }

      assert membership(:ezra, :platform)
      follow_redirect!
      assert_equal "Saved 1 of 2. Ada Quill is already in Platform", drawer.at_css("#org-unit-alert").text.strip
    end

    should "refuse an allocation that isn't a number without placing anyone" do
      post tenant_org_unit_members_path(@org[:payments]), params: { person_ids: [ @org[:ezra].id ], allocation: "lots" }

      assert_nil membership(:ezra, :payments)
      follow_redirect!
      assert_includes drawer.at_css("#org-unit-alert").text, "Allocation must be a number"
    end

    should "move a member to another unit and remove one" do
      patch tenant_org_unit_member_path(@org[:checkout], @org[:cyril].id), params: { unit_id: @org[:payments] }
      assert_redirected_to edit_tenant_org_unit_path(@org[:checkout])
      assert_nil membership(:cyril, :checkout)
      assert membership(:cyril, :payments)

      delete tenant_org_unit_member_path(@org[:payments], @org[:dot].id)
      assert_response :see_other
      assert_nil membership(:dot, :payments)
    end

    should "offer only active people as candidates" do
      get candidates_tenant_org_unit_path(@org[:platform], frame: "owner-candidates", q: "e")

      assert_response :success
      frame = Nokogiri::HTML5(response.body).at_css("turbo-frame#owner-candidates")
      assert_includes frame.text, "Ezra Pell"
      assert_includes frame.text, "Analyst"
      assert_not_includes frame.text, "Faye Lumen"
    end

    should "show each member's role and allocation, and ask one of people added" do
      get edit_tenant_org_unit_path(@org[:checkout])

      assert_includes drawer.text, "Tech lead · 50%"
      assert_select "input[name='allocation']", count: 1
    end
  end

  context "as the owner of Payments, who is neither an admin nor an editor" do
    setup do
      @owner_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        owner = create(:person, tenant: @tenant, name: "Gale Orrin")
        create(:tenant_user, tenant: @tenant, user: @owner_user, person: owner, role: :member)
        structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        structure.add_unit_owner(@org[:payments], owner.id, effective_on: "2026-01-01")
        structure.add_unit_owner(@org[:platform], @org[:ezra].id, effective_on: "2026-01-01")
      end
      sign_in @owner_user
    end

    should "find people by name and email, without their job titles" do
      get candidates_tenant_org_unit_path(@org[:payments], q: "e")

      frame = Nokogiri::HTML5(response.body).at_css("turbo-frame#member-candidates")
      assert_includes frame.text, "Ezra Pell"
      assert_not_includes frame.text, "Analyst"
      assert_not_includes frame.text, "Engineer"
    end

    should "show each member's role, but not their allocation" do
      get edit_tenant_org_unit_path(@org[:checkout])

      assert_includes drawer.text, "Tech lead"
      assert_not_includes drawer.text, "50%"
      get edit_tenant_org_unit_path(@org[:payments])
      assert_includes drawer.text, "Dot Fennick"
      assert_not_includes drawer.text, "100%"
    end

    should "add people to Payments without asking an allocation, and store none sent by hand" do
      get edit_tenant_org_unit_path(@org[:payments])
      assert_select "input[name='role']"
      assert_select "input[name='allocation']", count: 0

      post tenant_org_unit_members_path(@org[:payments]), params: { person_ids: [ @org[:ezra].id ], role: "Analyst", allocation: "50" }

      assert_nil flash[:drawer_alert]
      membership = ActsAsTenant.with_tenant(@tenant) { OrgMembership.find_by!(unit_id: @org[:payments], person_id: @org[:ezra].id) }
      assert_equal [ "Analyst", nil ], [ membership.role, membership.allocation ]
    end

    should "offer no form to retire, merge, split or move a unit out of reach" do
      steps = {
        new_tenant_org_unit_retirement_path(@org[:platform]) => tenant_org_unit_retirement_path(@org[:platform]),
        new_tenant_org_unit_merge_path(@org[:platform]) => tenant_org_unit_merge_path(@org[:platform]),
        new_tenant_org_unit_split_path(@org[:platform]) => tenant_org_unit_split_path(@org[:platform]),
        new_tenant_org_unit_structure_move_path(@org[:platform], parent_id: @org[:checkout]) =>
          tenant_org_unit_structure_move_path(@org[:platform])
      }
      steps.each do |step, action|
        get step

        assert_response :success, step
        assert_select "form[action='#{action}']", { count: 0 }, step
        assert_select "#org-unit-step-blocked", { count: 1 }, step
      end
    end

    should "change nothing outside Payments, through any write in the drawer" do
      sign_in @admin_user
      post tenant_org_unit_structure_declaration_path(@org[:checkout]), params: { start: "copy", conversion: { @org[:squad] => @org[:squad] } }
      assert_redirected_to edit_tenant_org_structure_path(@org[:checkout])
      sign_in @owner_user
      writes = [
        -> { patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" } } },
        -> { patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { level_id: @org[:squad] } } },
        -> { patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { parent_id: @org[:checkout] } } },
        -> { patch tenant_org_unit_path(@org[:payments]), params: { org_unit: { parent_id: @org[:platform] } } },
        -> { post tenant_org_unit_owners_path(@org[:platform]), params: { person_ids: [ @org[:ada].id ] } },
        -> { delete tenant_org_unit_owner_path(@org[:platform], @org[:ezra].id) },
        -> { post tenant_org_unit_members_path(@org[:platform]), params: { person_ids: [ @org[:ezra].id ] } },
        -> { patch tenant_org_unit_member_path(@org[:checkout], @org[:cyril].id), params: { unit_id: @org[:payments] } },
        -> { delete tenant_org_unit_member_path(@org[:platform], @org[:ada].id) },
        -> { post tenant_org_unit_retirement_path(@org[:platform]) },
        -> { post tenant_org_unit_merge_path(@org[:platform]), params: { into_unit_id: @org[:checkout] } },
        -> { post tenant_org_unit_split_path(@org[:platform]), params: { names: %w[Core Edge], placements: { @org[:ada].id => "Core" } } },
        -> { post tenant_org_unit_structure_declaration_path(@org[:platform]), params: { start: "copy", conversion: { @org[:squad] => @org[:squad] } } },
        -> { post tenant_org_unit_structure_withdrawal_path(@org[:checkout]), params: { conversion: { @org[:squad] => @org[:squad] } } },
        -> { post tenant_org_unit_structure_move_path(@org[:platform]), params: { parent_id: @org[:checkout], conversion: { @org[:team] => @org[:squad] } } }
      ]
      events = -> { Rails.configuration.event_store.read.count }
      count = events.call

      writes.each_with_index do |write, index|
        write.call
        assert_response :redirect, "write #{index}"
        assert_match REFUSAL, flash[:drawer_alert] || flash[:alert], "write #{index}"
      end

      assert_equal count, events.call
      assert_equal %w[Checkout Engineering Payments Platform], ActsAsTenant.with_tenant(@tenant) { OrgUnit.live.order(:name).pluck(:name) }
      assert_equal @org[:checkout], unit(:payments).parent_id
      assert membership(:ada, :platform)
      assert membership(:cyril, :checkout)
      assert_nil membership(:ezra, :platform)
      assert_nil membership(:cyril, :payments)
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "not open the drawer" do
      get edit_tenant_org_unit_path(@org[:platform])

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "not rename, own or staff a unit" do
      patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" } }
      post tenant_org_unit_owners_path(@org[:platform]), params: { person_ids: [ @org[:ada].id ] }
      delete tenant_org_unit_member_path(@org[:platform], @org[:ada].id)

      assert_equal "Platform", unit(:platform).name
      assert_empty unit(:platform).own_owners
      assert membership(:ada, :platform)
    end

    should "not change a unit's type" do
      patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { level_id: @org[:squad] } }

      assert_redirected_to root_path
      assert_equal @org[:team], unit(:platform).level_id
    end

    should "not search people" do
      get candidates_tenant_org_unit_path(@org[:platform], q: "e")

      assert_redirected_to root_path
    end
  end
end
