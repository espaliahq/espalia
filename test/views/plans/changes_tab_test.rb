# frozen_string_literal: true

require "test_helper"

class Views::Plans::ChangesTabTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cdc00"
  Q1 = "01a1da48-c64a-7529-af90-0f97e41cdc01"
  PAYMENTS = "01a1da48-c64a-7529-af90-0f97e41cdc02"
  GROWTH = "01a1da48-c64a-7529-af90-0f97e41cdc03"
  ADA = "01a1da48-c64a-7529-af90-0f97e41cdc04"
  BO = "01a1da48-c64a-7529-af90-0f97e41cdc05"

  SCENARIOS = [
    { scenario_id: PLAN, parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-15", ends_on: nil },
    { scenario_id: Q1, parent_id: PLAN, relation: "then", name: "Q1 hires", starts_on: "2027-01-01", ends_on: "2027-03-31" }
  ].freeze

  def drift_change(kind, **fields)
    { kind:, effective_on: "2026-11-20", learned_at: "2026-11-20T09:00:00Z", person_id: nil, unit_id: nil, from_unit_id: nil,
      succession_id: nil, fact: nil, before: nil, after: nil, provider: "espalia", event_id: SecureRandom.uuid,
      withdrawn: false, from_plan: false, meets: [], sources: %w[espalia], **fields }
  end

  def render_tab(changes: [], statuses: [], items: [], scenario_id: Q1, can_edit: false)
    drift = { plan_id: PLAN, from: "2026-11-14", to: "2026-11-30", changes:,
              names: { ADA => "Ada Quill", BO => "Bo Reyes", PAYMENTS => "Payments", GROWTH => "Growth" } }
    status = { plan_id: PLAN, scenario_id:, on: "2026-11-30", statuses:, names: { BO => "Bo Reyes" } }
    attention = { plan_id: PLAN, scenario_id:, items:, names: { ADA => "Ada Quill" } }
    plan = { plan_id: PLAN, name: "Pay review", base_on: "2026-11-15" }
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::ChangesTab.new(plan:, scenarios: SCENARIOS, drift:, status:, attention:,
                                                                                                                can_edit:)))
  end

  def noted(note, scenario_id: Q1, change_id: "c1")
    { scenario_id:, change_id:, subject_id: BO, facet: "level", status: "pending", since: nil, sources: %w[espalia],
      **({ note: } if note) }
  end

  def texts(html, selector) = html.css(selector).map { it.text.squish }

  context "the Org Graph's changes" do
    should "say what each one did, in words, with when it takes effect and where it comes from" do
      html = render_tab(changes: [
        drift_change("moved", person_id: BO, unit_id: GROWTH, from_unit_id: PAYMENTS, sources: %w[espalia hibob]),
        drift_change("fact_changed", person_id: ADA, fact: "manager", before: { "manager_id" => BO }, after: { "manager_id" => "gone" }),
        drift_change("fact_changed", person_id: ADA, fact: "title", before: nil, after: { "title" => "Staff Engineer" },
                                     effective_on: "2026-11-01"),
        drift_change("left", person_id: BO, withdrawn: true),
        drift_change("membership_started", person_id: ADA, unit_id: "gone-unit")
      ])

      rows = texts(html, "[data-drift-change]")
      assert_includes rows[0], "Bo Reyes moved from Payments to Growth"
      assert_includes rows[0], "Source: Espalia"
      assert_includes rows[0], "Source: HiBob"
      assert_includes rows[1], "Ada Quill's manager changed from Bo Reyes to #{Person::FORMER_MEMBER}"
      assert_includes rows[2], "Ada Quill's title is now Staff Engineer"
      assert_includes rows[2], "Takes effect 1 Nov · learned 20 Nov"
      assert_includes rows[3], "Withdrawn"
      assert html.at_css("[data-drift-change='left'] .line-through")
      assert_includes rows[4], "Ada Quill joined #{Views::Plans::ChangesTab::REMOVED_UNIT}"
    end

    should "mark a change from this plan, and link each scenario whose plan it meets" do
      html = render_tab(changes: [ drift_change("joined", person_id: ADA, from_plan: true,
                                                          meets: [ { scenario_id: PLAN }, { scenario_id: Q1 }, { scenario_id: Q1 } ]) ])

      row = html.at_css("[data-drift-change='joined']")
      assert_includes row.text, "From this plan"
      assert_equal [ "Today", "Q1 hires" ], row.css("a").map(&:text)
      assert_equal "/planning/#{PLAN}/changes", row.css("a").first["href"]
    end

    should "say when nothing has changed" do
      assert_includes render_tab.text, "Nothing has changed in the Org Graph since the base."
    end
  end

  context "the planned changes" do
    should "give each its status, the day a carried conflict began, and the scenario it was inherited from" do
      html = render_tab(statuses: [
        { scenario_id: PLAN, change_id: "c1", subject_id: BO, facet: "assignment", status: "done", since: nil, sources: %w[hibob] },
        { scenario_id: Q1, change_id: "c2", subject_id: BO, facet: "level", status: "conflicting", since: "2026-11-21", sources: %w[espalia] },
        { scenario_id: Q1, change_id: "c3", subject_id: "new-unit", facet: "unit", status: "pending", since: nil, sources: %w[espalia] }
      ])

      rows = texts(html, "[data-planned-change]")
      assert_includes rows[0], "Bo Reyes · Placement"
      assert_includes rows[0], "Done"
      assert_includes rows[0], "Planned in Today"
      assert_includes rows[0], "Source: HiBob"
      assert_includes rows[1], "Conflicting since 21 Nov"
      assert_not_includes rows[1], "Planned in"
      assert_includes rows[2], "#{Views::Plans::ChangesTab::PLAN_ONLY} · Unit"
    end

    should "read a withdrawn departure as staying, conflicting once the person has left" do
      rows = texts(render_tab(statuses: [
        { scenario_id: Q1, change_id: "d1", subject_id: BO, facet: "departure", status: "conflicting", since: nil, sources: %w[hibob], staying: true }
      ]), "[data-planned-change='conflicting']")

      assert_equal 1, rows.size
      assert_includes rows.sole, "Bo Reyes · #{Views::Plans::ChangesTab::STAYING}"
      assert_includes rows.sole, "Source: HiBob"
    end

    should "badge every status the query gives, a plan-only change included, with no fallback" do
      statuses = TeamPlanning::Status::STATUSES.map do |status|
        { scenario_id: Q1, change_id: status.to_s, subject_id: BO, facet: "data:pay", status: status.to_s, since: nil, sources: [] }
      end
      rows = texts(render_tab(statuses:), "[data-planned-change]")

      assert_equal [ "Done", "Pending", "Conflicting", "Unknown", "Plan only" ], rows.map { it.delete_prefix("Bo Reyes · Pay").strip }
      assert_raises(KeyError) { render_tab(statuses: [ statuses.first.merge(status: "stalled") ]) }
    end

    should "name a rule by its kind, a plan-wide rule by the plan, a plan value apart from a level change, and a hire only the plan holds" do
      html = render_tab(statuses: [
        { scenario_id: Q1, change_id: "r1", subject_id: BO, facet: "rule:on_cost", status: "plan_only", since: nil, sources: [] },
        { scenario_id: Q1, change_id: "h1", subject_id: "hire", facet: "placeholder", status: "plan_only", since: nil, sources: [] },
        { scenario_id: Q1, change_id: "r2", subject_id: PLAN, facet: "rule:on_cost", status: "plan_only", since: nil, sources: [] },
        { scenario_id: Q1, change_id: "l1", subject_id: BO, facet: "data:level", status: "plan_only", since: nil, sources: [] }
      ])

      assert_equal [ "Bo Reyes · RulePlan only", "#{Views::Plans::ChangesTab::PLAN_ONLY} · HirePlan only",
                     "#{Views::Plans::ChangesTab::WHOLE_PLAN} · RulePlan only", "Bo Reyes · Level (plan value)Plan only" ],
                   texts(html, "[data-planned-change='plan_only']")
    end

    should "name the scenario shown, and mark it in the picker" do
      html = render_tab
      assert_equal "Planned in Q1 hires", html.at_css("#changes-planned-heading").text
      assert_equal "Q1 hires", html.at_css("nav[aria-label='Scenario'] a[aria-current='page']").text
      assert_equal Q1, html.at_css("#changes-scenario option[selected]")["value"]
      assert_equal "", html.css("#changes-scenario option").find { it.text == "Today" }["value"], "Today is the bare URL, as its pill is"
      assert_includes html.text, "This scenario plans nothing yet."
    end
  end

  context "a planned change's note" do
    should "render a note as prose, mark an erased one as removed, and show nothing without one" do
      html = render_tab(statuses: [ noted({ value: "Promo **agreed** in March" }, change_id: "c1"),
                                    noted({ removed: true }, change_id: "c2"), noted(nil, change_id: "c3") ])

      rows = html.css("[data-planned-change]")
      assert_equal %w[change-c1 change-c2 change-c3], rows.map { it["id"] }, "the Checks tab links each change by its row's id"
      assert_equal "agreed", rows[0].at_css("[data-change-note].md-prose strong").text
      assert_equal "Note removed", rows[1].at_css("[data-change-note='removed']").text
      assert_nil rows[2].at_css("[data-change-note]")
    end

    should "offer no note form to a viewer who can't edit" do
      assert_nil render_tab(statuses: [ noted({ value: "x" }) ]).at_css("[data-change-note-editor]")
    end

    should "offer no note form on a change whose note was erased with its person" do
      assert_nil render_tab(statuses: [ noted({ removed: true }) ], can_edit: true).at_css("[data-change-note-editor]")
    end

    should "let an editor rewrite a note on the scenario that made the change" do
      html = render_tab(statuses: [ noted({ value: "Promo in March" }, scenario_id: PLAN, change_id: "c1"), noted(nil, change_id: "c2") ],
                        can_edit: true)

      editors = html.css("[data-change-note-editor]")
      assert_equal [ "Edit note", "Add a note" ], editors.map { it.at_css("summary").text }
      form = editors[0].at_css("form")
      assert_equal "/planning/#{PLAN}/notes/c1", form["action"]
      assert_equal "patch", form.at_css("input[name='_method']")["value"]
      assert_equal PLAN, form.at_css("input[name='note[scenario_id]']")["value"], "an inherited change is noted where it was made"
      assert_equal Q1, form.at_css("input[name='shown']")["value"]
      assert_equal "Promo in March", form.at_css("textarea[name='note[text]']").text
      assert_equal "change-note-c1-hint", form.at_css("textarea")["aria-describedby"]
      assert_includes form.at_css("#change-note-c1-hint").text, "It is saved on Today, so every scenario that follows it shows it."
      assert_not_includes editors[1].at_css("#change-note-c2-hint").text, "It is saved on"
      assert_equal "Note", form.at_css("label[for='change-note-c1']").text
    end
  end

  context "what needs attention" do
    should "list each item with its reason" do
      html = render_tab(items: [ { subject_id: ADA, facet: "assignment", reason: "Placed, but has left", change: nil, sources: %w[hibob] } ])
      row = html.at_css("[data-attention-item='assignment']")
      assert_equal [ "Ada Quill · Placement", "Placed, but has left" ], row.css("p").map { it.text.squish }
      assert_includes row.text, "Source: HiBob"
    end

    should "name a unit it can, and never call one it can't only the plan's" do
      html = render_tab(items: [ { subject_id: PAYMENTS, facet: "unit", reason: "Its parent was retired", change: nil, sources: %w[espalia] },
                                 { subject_id: "elsewhere", facet: "unit", reason: "Its parent was retired", change: nil, sources: %w[espalia] } ])
      assert_equal [ "Payments · Unit", "Unit" ], html.css("[data-attention-item] p:first-child").map { it.text.squish }
    end
  end
end
