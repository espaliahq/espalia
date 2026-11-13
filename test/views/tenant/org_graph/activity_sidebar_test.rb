# frozen_string_literal: true

require "test_helper"

class Views::Tenant::OrgGraph::ActivitySidebarTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @user = create(:user)
    @admin = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :admin) }
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def render_sidebar(unit_id, page: 1)
    as_tenant do
      context = AuthorizationContext.new(user: @user, tenant_user: @admin, person: nil)
      feed = OrgGraph::ActivityFeed.new(unit: OrgUnit.find(unit_id), actor: context, page:)
      controller = ApplicationController.new
      controller.request = ActionDispatch::TestRequest.create
      Nokogiri::HTML5(controller.view_context.render(Views::Tenant::OrgGraph::ActivitySidebar.new(feed:)))
    end
  end

  def handler(**options) = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, **options)

  should "list the unit's groups newest first, each with who, when it took effect and when it was learned" do
    travel_to Time.zone.parse("2027-03-01 09:00")
    rows = render_sidebar(@org[:platform]).css("ol > li")

    assert_equal [ "Added Brook Tamsin", "Added Ada Quill", "Created the unit" ], rows.map { it.at_css("p").text }
    assert_match(/\AEspalia · took effect 5 Jan 2026, learned/, rows.first.css("p")[1].text)
    assert_equal "2026-01-05", rows.first.at_css("time")["datetime"]
  end

  should "offer change it back where it would work, and give the reason where it wouldn't" do
    rows = render_sidebar(@org[:platform]).css("ol > li")

    form = rows.first.at_css("form")
    assert_equal "/tenant/org_graph/change_back", form["action"]
    assert_equal OrgUnitActivity.find_by(id: form.at_css("input[name='entry_id']")["value"]).person_id, @org[:brook].id
    assert_equal "Change it back", form.at_css("button").text
    assert_nil rows.last.at_css("form")
    assert_includes rows.last.text, "Can't change back: Unit Created can't be changed back"
  end

  should "open a group's parts, change it back by its cause, and say it reaches every unit it touched" do
    as_tenant do
      handler(cause_id: "request-1").tap do |request|
        request.move_membership(@org[:cyril].id, @org[:checkout], @org[:platform], effective_on: "2026-02-01")
        request.move_membership(@org[:dot].id, @org[:payments], @org[:platform], effective_on: "2026-02-01")
      end
    end

    group = render_sidebar(@org[:platform]).at_css("ol > li")

    assert_equal "Moved 2 people in", group.at_css("p").text
    assert_equal "Show 2 parts", group.at_css("details summary").text
    assert_equal [ "Moved Dot Fennick in from Payments", "Moved Cyril Moss in from Checkout" ],
      group.css("details li > p:first-child").map(&:text)
    assert_equal 2, group.css("details form input[name='entry_id']").size
    whole = group.css("> form").last
    assert_equal [ "request-1", "Change it all back" ], [ whole.at_css("input[name='cause_id']")["value"], whole.text.strip ]
    assert_includes group.text, "This changes it back in all 3 units it touched."
  end

  should "show a plan reference, and mark a change already changed back" do
    entry = as_tenant do
      handler.set_membership(@org[:ezra].id, @org[:platform], provider: "espalia", effective_on: "2026-02-01",
                                                               plan_id: "plan-7", plan_change_id: "change-3")
      OrgUnitActivity.for_unit(@org[:platform]).first
    end
    as_tenant { OrgGraph::ChangeBackHandler.new(actor: OrgGraph::Authorization::SYSTEM).change_back(entry) }

    row = render_sidebar(@org[:platform]).css("ol > li")[1]

    assert_includes row.text, "From plan plan-7, change change-3"
    assert row.at_css(".tone-neutral")&.text == "Changed back"
    assert_nil row.at_css("form")
  end

  should "shorten a UUID plan reference to its random tail, keeping the whole id in its title" do
    plan_id = "0193a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    as_tenant do
      handler.set_membership(@org[:ezra].id, @org[:platform], provider: "espalia", effective_on: "2026-02-01",
                                                               plan_id:)
    end

    code = render_sidebar(@org[:platform]).at_css("ol > li code")

    assert_equal "…2e3f4a5b", code.text
    assert_equal plan_id, code["title"]
  end

  should "name a forgotten person as a former member" do
    as_tenant { @org[:brook].update_columns(name: Person::FORMER_MEMBER, forgotten_at: Time.current) }

    assert_equal "Added Former member", render_sidebar(@org[:platform]).at_css("ol > li p").text
  end

  should "say so when the unit has no activity yet" do
    as_tenant { OrgUnitActivity.where(unit_id: @org[:platform]).delete_all }

    sidebar = render_sidebar(@org[:platform])

    assert_includes sidebar.text, "No activity yet"
    assert_nil sidebar.at_css("ol")
  end

  should "link to older and newer pages" do
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      25.times { |i| structure.rename_unit(@org[:platform], "Platform #{i}", effective_on: "2026-02-01") }
    end

    first = render_sidebar(@org[:platform]).css("nav[aria-label='Activity pages'] a").map(&:text)
    second = render_sidebar(@org[:platform], page: 2).css("nav[aria-label='Activity pages'] a").map(&:text)

    assert_equal [ [ "Older" ], [ "Newer" ] ], [ first, second ]
  end
end
