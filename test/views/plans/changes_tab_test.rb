# frozen_string_literal: true

require "test_helper"

class Views::Plans::ChangesTabTest < ActiveSupport::TestCase
  PLAN = "01a1da48-c64a-7529-af90-0f97e41cdc00"
  Q1 = "01a1da48-c64a-7529-af90-0f97e41cdc01"
  PAYMENTS = "01a1da48-c64a-7529-af90-0f97e41cdc02"
  GROWTH = "01a1da48-c64a-7529-af90-0f97e41cdc03"
  ADA = "01a1da48-c64a-7529-af90-0f97e41cdc04"
  BO = "01a1da48-c64a-7529-af90-0f97e41cdc05"
  PLAN_B = "01a1da48-c64a-7529-af90-0f97e41cdc06"

  SCENARIOS = [
    { scenario_id: PLAN, parent_id: nil, relation: nil, name: "Pay review", starts_on: "2026-11-15", ends_on: nil },
    { scenario_id: Q1, parent_id: PLAN, relation: "then", name: "Q1 hires", starts_on: "2027-01-01", ends_on: "2027-03-31" }
  ].freeze

  def drift_change(kind, **fields)
    { kind:, effective_on: "2026-11-20", learned_at: "2026-11-20T09:00:00Z", person_id: nil, unit_id: nil, from_unit_id: nil,
      succession_id: nil, fact: nil, before: nil, after: nil, provider: "espalia", event_id: SecureRandom.uuid,
      withdrawn: false, from_plan: false, meets: [], sources: %w[espalia], **fields }
  end

  def render_tab(changes: [], statuses: [], items: [], scenario_id: Q1, can_edit: false, scenarios: SCENARIOS)
    drift = { plan_id: PLAN, from: "2026-11-14", to: "2026-11-30", changes:,
              names: { ADA => "Ada Quill", BO => "Bo Reyes", PAYMENTS => "Payments", GROWTH => "Growth" } }
    status = { plan_id: PLAN, scenario_id:, on: "2026-11-30", statuses:, names: { BO => "Bo Reyes" } }
    attention = { plan_id: PLAN, scenario_id:, items:, names: { ADA => "Ada Quill" } }
    plan = { plan_id: PLAN, name: "Pay review", base_on: "2026-11-15" }
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    Nokogiri::HTML5.fragment(controller.view_context.render(Views::Plans::ChangesTab.new(plan:, scenarios:, drift:, status:, attention:,
                                                                                                                can_edit:)))
  end

  def noted(note, scenario_id: Q1, change_id: "c1")
    { scenario_id:, change_id:, subject_id: BO, facet: "level", status: "pending", since: nil, sources: %w[espalia],
      **({ note: } if note) }
  end

  def clearable(scenario_id: Q1, **fields) = noted(nil, scenario_id:).merge(status: "plan_only", clearable: true, **fields)

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
      assert_includes rows[4], "Ada Quill joined #{TeamPlanning::Attention::REMOVED_UNIT}"
    end

    should "say a covered person or unit left the plan's units without naming where they went" do
      html = render_tab(changes: [
        drift_change("moved", person_id: BO, unit_id: nil, from_unit_id: PAYMENTS, outside: [ "unit_id" ]),
        drift_change("moved", person_id: ADA, unit_id: GROWTH, from_unit_id: nil, outside: [ "from_unit_id" ]),
        drift_change("fact_changed", person_id: ADA, fact: "manager", before: { "manager_id" => BO }, after: { "manager_id" => nil },
                                     outside: [ "after" ]),
        drift_change("unit_moved", unit_id: PAYMENTS, before: { "parent_id" => GROWTH }, after: { "parent_id" => nil }, outside: [ "after" ]),
        drift_change("owner_added", person_id: nil, unit_id: PAYMENTS, outside: [ "person_id" ])
      ])

      assert_equal [ "Bo Reyes left the units this plan covers", "Ada Quill joined Growth from outside the units this plan covers",
                     "Ada Quill's manager changed from Bo Reyes to someone outside this plan", "Payments left the units this plan covers",
                     "Someone outside this plan became an owner of Payments" ],
                   html.css("[data-drift-change] .break-words").map { it.text.squish }
    end

    should "read a removed manager as no manager, not as someone outside the plan" do
      html = render_tab(changes: [ drift_change("fact_changed", person_id: ADA, fact: "manager", before: { "manager_id" => BO },
                                                                after: { "manager_id" => nil }) ])

      assert_equal [ "Ada Quill's manager changed" ], html.css("[data-drift-change] .break-words").map { it.text.squish }
    end

    should "give only the new value when the earlier one was set while its subject was outside the plan" do
      html = render_tab(changes: [ drift_change("fact_changed", person_id: ADA, fact: "title", before: nil, after: { "title" => "Staff Engineer" },
                                                                outside: [ "before" ]),
                                   drift_change("fact_changed", person_id: ADA, fact: "manager", before: nil, after: { "manager_id" => BO },
                                                                outside: [ "before" ]),
                                   drift_change("unit_renamed", unit_id: PAYMENTS, before: nil, after: { "name" => "Platform" }, outside: [ "before" ]) ])

      assert_equal [ "Ada Quill's title is now Staff Engineer", "Ada Quill's manager is now Bo Reyes", "Renamed Platform" ],
                   html.css("[data-drift-change] .break-words").map { it.text.squish }
    end

    should "mark a change from this plan, and link each scenario whose plan it meets" do
      html = render_tab(changes: [ drift_change("joined", person_id: ADA, from_plan: true,
                                                          meets: [ { scenario_id: PLAN }, { scenario_id: Q1 }, { scenario_id: Q1 } ]) ])

      row = html.at_css("[data-drift-change='joined']")
      assert_includes row.text, "From this plan"
      assert_equal [ "Today", "Q1 hires" ], row.css("a").map(&:text)
      assert_equal "/planning/#{PLAN}/changes", row.css("a").first["href"]
    end

    should "settle from the drift row only what conflicts in the scenario on screen, and count the others" do
      meets = [ { scenario_id: Q1, change_id: "c2", facet: "level", subject_id: BO }, { scenario_id: PLAN, change_id: "c9", facet: "level", subject_id: BO } ]
      carried = { scenario_id: Q1, change_id: "c2", subject_id: BO, facet: "level", status: "conflicting", since: "2026-11-21", sources: %w[espalia] }
      html = render_tab(changes: [ drift_change("fact_changed", person_id: BO, fact: "level", meets:) ], statuses: [ carried ], can_edit: true)

      row = html.at_css("[data-drift-change='fact_changed']")
      settle = row.at_css("[data-drift-settle='#{Q1}']")
      assert_includes settle.text, "Conflicts with the plan in Q1 hires."
      assert_equal %w[plan reality], settle.css("[data-settle-conflict='level'] button").map { it["value"] }
      assert_equal Q1, settle.at_css("input[name='settlement[scenario_id]']")["value"]
      elsewhere = settle.at_css("[data-drift-settle-elsewhere='1']")
      assert_includes elsewhere.text, "Also planned in 1 other scenario"
      assert_equal [ "/planning/#{PLAN}/changes" ], elsewhere.css("a").map { it["href"] }
      assert_not_includes row.text, "Meets the plan in"
    end

    should "link the scenario a child inherits its conflict from, which settling in the child leaves alone" do
      meets = [ { scenario_id: PLAN, change_id: "c9", facet: "level", subject_id: BO } ]
      inherited = { scenario_id: PLAN, change_id: "c9", subject_id: BO, facet: "level", status: "conflicting", since: "2026-11-21", sources: %w[espalia] }
      html = render_tab(changes: [ drift_change("fact_changed", person_id: BO, fact: "level", meets:) ], statuses: [ inherited ], can_edit: true)

      settle = html.at_css("[data-drift-settle='#{Q1}']")
      assert_equal %w[plan reality], settle.css("button").map { it["value"] }
      assert_equal [ "/planning/#{PLAN}/changes" ], settle.css("[data-drift-settle-elsewhere='1'] a").map { it["href"] }
    end

    should "offer no drift-row buttons for a live conflict or to a viewer" do
      meets = [ { scenario_id: Q1, change_id: "c2", facet: "level", subject_id: BO } ]
      drift = [ drift_change("fact_changed", person_id: BO, fact: "level", meets:) ]
      live = { scenario_id: Q1, change_id: "c2", subject_id: BO, facet: "level", status: "conflicting", since: nil, sources: %w[espalia] }

      assert_nil render_tab(changes: drift, statuses: [ live ], can_edit: true).at_css("[data-drift-settle]")
      assert_nil render_tab(changes: drift, statuses: [ live.merge(since: "2026-11-21") ]).at_css("[data-drift-settle]")
      assert_includes render_tab(changes: drift, statuses: [ live ], can_edit: true).at_css("[data-drift-change]").text, "Meets the plan in Q1 hires"
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

      assert_equal [ "Done", "Pending", "Conflicting", "Unknown", "Plan only", "Outside this plan" ],
                   rows.map { it.sub(/\A(Bo Reyes|#{Views::Plans::ChangesTab::NO_LONGER_COVERED}) · Pay/, "").strip }
      assert_raises(KeyError) { render_tab(statuses: [ statuses.first.merge(status: "stalled") ]) }
    end

    should "offer an editor Clear, Undo and a note on a change about someone the plan no longer covers, and name no one" do
      outside = { scenario_id: Q1, change_id: "o1", subject_id: BO, facet: "level", status: "outside", clearable: true, undoable: true }
      html = render_tab(statuses: [ outside ], scenario_id: Q1, can_edit: true)
      row = html.at_css("[data-planned-change='outside']")
      label = "#{Views::Plans::ChangesTab::NO_LONGER_COVERED} · Level"

      assert_includes row.text.squish, label
      assert_not_includes html.to_html, "Bo Reyes"
      assert_equal [ "Clear #{label}" ], row.css("[data-clear-change]").map { it["aria-label"] }
      assert_equal "Clear this level change?", row.at_css("[id^='clear-'][role='dialog'] h2").text.squish
      assert_equal [ "Undo #{label}" ], row.css("[data-undo-change='level'] button").map { it["aria-label"] }
      assert_equal({ "scenario_id" => Q1, "event_id" => "o1", "tab" => "changes" },
                   row.css("form[action$='/change-undos'] input[type=hidden]").to_h { [ it["name"], it["value"] ] }.except("authenticity_token"))
      assert_empty row.css("[data-settle-conflict]")
      assert_equal "Add a note", row.at_css("[data-change-note-editor] summary").text.squish, "a note acts on the plan's own change"
      noted = render_tab(statuses: [ outside.merge(note: { value: "Agreed in March" }) ], scenario_id: Q1).at_css("[data-planned-change='outside']")
      assert_equal "Agreed in March", noted.at_css("[data-change-note]").text.squish
      assert_empty render_tab(statuses: [ outside ], scenario_id: Q1).css("[data-clear-change], [data-undo-change]"), "a viewer gets no buttons"
      assert_empty render_tab(statuses: [ outside.merge(clearable: false) ], scenario_id: Q1, can_edit: true).css("[data-undo-change]")
      bringing_back = render_tab(statuses: [ outside.merge(undoable: false) ], scenario_id: Q1, can_edit: true)
      assert_equal [ [ "Clear #{label}" ], [] ], [ bringing_back.css("[data-clear-change]").map { it["aria-label"] }, bringing_back.css("[data-undo-change]").to_a ],
                   "an undo that would bring an earlier change back is not offered"
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

    should "clamp a note only where it can run past three lines, counting no blank line" do
      paragraphs = "Moved for on-call\n\nAgreed with Bo\n\nRevisit in Q3"
      rows = render_tab(statuses: [ noted({ value: "Short and done" }, change_id: "c1"), noted({ value: paragraphs }, change_id: "c2"),
                                    noted({ value: "a medium note " * 12 }, change_id: "c3"), noted({ value: "a long note " * 40 }, change_id: "c4"),
                                    noted({ value: "one\ntwo\nthree\nfour" }, change_id: "c5") ]).css("[data-planned-change]")
      toggles = rows.map { it.at_css("[data-change-note-more]")&.[]("class")&.split }

      assert_nil toggles[0]
      assert_nil toggles[1], "three paragraphs show in three lines"
      assert_includes toggles[2], "md:hidden", "a medium note fits a wide row's three lines"
      assert_includes rows[2].at_css("[data-change-note]")["class"].split, "md:line-clamp-none"
      [ 3, 4 ].each { assert_not_includes toggles[it], "md:hidden" }
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

    should "offer only keeping the plan on a carried succession conflict, which can't follow reality" do
      carried = ->(facet, id) { { scenario_id: Q1, change_id: id, subject_id: BO, facet:, status: "conflicting", since: "2026-11-21", sources: %w[espalia] } }
      html = render_tab(statuses: [ carried.("level", "c1"), carried.("succession", "c2") ], can_edit: true)

      assert_equal %w[plan reality], html.css("[data-settle-conflict='level'] button").map { it["value"] }
      succession = html.at_css("[data-settle-conflict='succession']")
      assert_equal %w[plan], succession.css("button").map { it["value"] }
      assert_includes succession.text, "change the succession on the map"
    end
  end

  context "what needs attention" do
    should "count the items and link to the Checks tab for the same scenario, leaving the items there" do
      items = [ { subject_id: ADA, facet: "assignment", reason: "Placed, but has left", change: nil, sources: %w[hibob] },
                { subject_id: PAYMENTS, facet: "unit", reason: "Its parent was retired", change: nil, sources: %w[espalia] } ]
      section = render_tab(items:).at_css("[data-changes-section='attention']")

      assert_equal "2 items in Q1 hires no longer fit. Review them in Checks", section.at_css("[data-attention-count='2']").text.squish
      assert_equal Rails.application.routes.url_helpers.checks_plan_path(PLAN, scenario: Q1), section.at_css("a")["href"]
      assert_not_includes section.text, "Placed, but has left"
    end

    should "link the baseline's count to Checks with no scenario, and say when nothing needs attention" do
      one = [ { subject_id: ADA, facet: "assignment", reason: "Placed, but has left", change: nil, sources: [] } ]
      section = render_tab(items: one, scenario_id: PLAN).at_css("[data-changes-section='attention']")
      assert_includes section.text.squish, "1 item in Today no longer fits."
      assert_equal Rails.application.routes.url_helpers.checks_plan_path(PLAN), section.at_css("a")["href"]

      empty = render_tab.at_css("[data-changes-section='attention']")
      assert_includes empty.text, "Everything in this scenario still fits."
      assert_nil empty.at_css("a")
    end
  end

  context "clearing a change" do
    should "offer Clear on a row an editor may clear, saying the scenario follows its own parent again" do
      alternative = { scenario_id: PLAN_B, parent_id: Q1, relation: "instead", name: "Plan B", starts_on: "2027-01-01", ends_on: "2027-03-31" }
      html = render_tab(statuses: [ clearable(scenario_id: PLAN_B) ], scenario_id: PLAN_B, can_edit: true, scenarios: SCENARIOS + [ alternative ])

      assert_equal [ "Clear Bo Reyes · Level" ], html.css("[data-clear-change]").map { it["aria-label"] }
      assert_includes html.at_css("[id^='clear-'][role='dialog']").text.squish,
                      "Plan B will follow Q1 hires again here. The change stays in the history, and Undo brings it back."
      assert_equal({ "scenario_id" => PLAN_B, "subject_id" => BO, "facet" => "level", "tab" => "changes" },
                   html.css("form[action$='/clears'] input[type=hidden]").to_h { [ it["name"], it["value"] ] }.except("authenticity_token"))
    end

    should "offer no Clear on a row the read marks unclearable, nor to a viewer" do
      assert_empty render_tab(statuses: [ clearable(clearable: false) ], can_edit: true).css("[data-clear-change]")
      assert_empty render_tab(statuses: [ clearable ]).css("[data-clear-change]")
    end
  end
end
