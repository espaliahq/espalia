# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CapacityModels::UnitsTest < ActiveSupport::TestCase
  Model = TeamPlanning::CapacityModel
  Units = TeamPlanning::CapacityModels::Units
  Baseline = TeamPlanning::Baseline

  # root
  # ├── team: manager M, reports A (L3) and B (L1), open seat P (L2, 0.5 FTE)
  # │   └── squad: A manages C (L4), C manages D (L3); open seat Q
  # └── studio: vacant manager seat V; F reports to V, E has no line, G reports to M; open seat W
  setup do
    @units = [ unit("root"), unit("team", "root"), unit("squad", "team"), unit("studio", "root") ]
    @people = [
      member("m", "team"), member("a", "squad", manager_id: "m"), member("b", "team", manager_id: "m"),
      member("c", "squad", manager_id: "a"), member("d", "squad", manager_id: "c"),
      member("e", "studio"), member("f", "studio", manager_position_id: "v"), member("g", "studio", manager_id: "m")
    ]
    @positions = [ position("p", "team"), position("q", "squad"), position("v", "studio"), position("w", "studio"), position("lone", "root") ]
    @levels = { "m" => 5, "a" => 3, "b" => 1, "c" => 4, "d" => 3, "e" => 3, "f" => 3, "g" => 3, "p" => 2, "q" => 3, "v" => 5, "w" => 3,
                "lone" => 3 }
    @open = { "p" => Rational(1, 2), "q" => 1r, "v" => 1r, "w" => 1r, "lone" => 1r }
    @roles = {}
  end

  def unit(id, parent_id = nil) = Baseline::Unit.new(id:, name: id, parent_id:, level_id: nil, owner_ids: [])

  def member(id, unit_id, manager_id: nil, manager_position_id: nil, departure: nil, position_id: nil)
    Baseline::Member.new(id:, title: nil, level: nil, manager_id:, cost_centre: nil, site: nil, country: nil, fte: 1, employment_type: nil,
                         memberships: [ Baseline::Membership.new(unit_id:, allocation: 1.0, role: nil, position_id:) ], manager_position_id:,
                         departure:)
  end

  def position(id, unit_id) = Baseline::Position.new(id:, role_id: nil, level_id: nil, unit_id:, fte: 1, basis: "new", role_name: nil, level_name: nil)

  def map = Baseline::Map.new(base_on: nil, known_on: nil, units: @units, successions: [], people: @people, unassigned_ids: [],
                              positions: @positions, names: {}, rules: nil)

  def facts
    @facts ||= Model::Facts.new(level_of: @levels, ordinal_of: (1..99).to_h { [ "L#{it}", it ] }, role_ids_of: @roles, open_fte: @open)
  end

  def price(id, params: {}, ordinal: @levels[id], allocation: 1r, allocation_known: true, fte: @open.fetch(id, 1r), fte_known: true)
    place = Model::Place.new(unit_id: nil, allocation:, allocation_known:, role_id: nil, level_id: ordinal && "L#{ordinal}", position_id: nil)
    seat = Model::Seat.new(id:, kind: @open.key?(id) ? "position" : "person", fte:, fte_known:, places: [ place ])
    figure = Units.capacity_of(seat, place:, params:, map:, facts:)
    assert_reaches figure
    figure
  end

  def assert_reaches(figure)
    return if figure.reason

    reached = figure.working.reduce(0r) do |total, step|
      case step.op
      when "+" then total + step.amount
      when "×" then total * step.amount
      when "="
        assert_equal total, step.amount
        total
      end
    end
    assert_equal figure.amount, reached
    assert_equal "=", figure.working.last.op
  end

  def costs(figure) = figure.working.select(&:subject_id).to_h { [ it.subject_id, -it.amount ] }

  should "rise linearly to the knee and saturate beyond it, never past its cap" do
    bases = (1..8).map { price("x", ordinal: it).amount }

    assert_equal [ "0.4", "0.7", "1.0", "1.3", "1.45", "1.525", "1.5625", "1.58125" ].map { Rational(it) }, bases
    near_cap = price("x", ordinal: 60).amount
    assert_operator near_cap, :<, Rational("1.6")
    assert_operator Rational("1.6") - near_cap, :<, Rational(1, 10**15)
    assert_equal [ "Base at L3", "Units" ], price("x", ordinal: 3).working.map(&:label)
  end

  should "read a level below 1 on the same line, never below zero, so a seat that manages nobody is never overloaded" do
    @facts = Model::Facts.new(level_of: @levels, ordinal_of: { "L0" => 0, "L-1" => -1 }, role_ids_of: @roles, open_fte: @open)

    assert_equal Rational("0.1"), price("x", ordinal: 0).amount
    assert_equal [ 0r, false ], price("x", ordinal: -1).then { [ it.amount, it.overloaded ] }
    assert_equal Rational("-0.05"), price("m", ordinal: 0, params: { "fixed_cost" => { "by_level" => { "0" => "0.05" } } }).working.second.amount
  end

  should "follow a tenant's own curve" do
    params = { "base" => { "start" => "1", "slope" => "0.5", "knee" => 2, "decay" => "0" } }

    assert_equal [ 1r, Rational(3, 2), Rational(3, 2) ], (1..3).map { price("x", ordinal: it, params:).amount }
  end

  should "refuse a negative, a decay of 1 or more, a fractional level and an unknown key, naming the key and never its value" do
    refusals = [
      { "base" => { "slope" => "-0.31415" } }, { "base" => { "decay" => "1.31415" } }, { "base" => { "knee" => "2.31415" } },
      { "fixed_cost" => { "by_level" => { "1.31415" => "0.1" } } }, { "per_report" => { "cousin" => "0.31415" } },
      { "curve" => "0.31415" }, { "manager_role_ids" => "0.31415" }
    ]

    refusals.each do |params|
      error = assert_raises(TeamPlanning::Error) { Units.check(params) }
      assert_no_match "31415", error.message
    end
    assert_match "slope", assert_raises(TeamPlanning::Error) { Units.check(refusals.first) }.message
    assert_match "cousin", assert_raises(TeamPlanning::Error) { Units.check(refusals[4]) }.message
    assert_equal({}, Units.check({}))
    assert_equal Units::DEFAULTS, Units.check(Units::DEFAULTS)
  end

  should "charge a manager a fixed cost and a cost per report by distance, weighted by level and by an open seat's FTE" do
    figure = price("m")

    assert_equal({ "a" => Rational("0.1"), "b" => Rational("0.15"), "g" => Rational("0.1"), "p" => Rational("0.0625"),
                   "c" => Rational("0.03"), "d" => Rational("0.01") }, costs(figure))
    assert_equal "Fixed cost of managing at L5", figure.working.second.label
    assert_equal Rational("1.45") - Rational("0.1") - Rational("0.4525"), figure.amount
    assert_includes figure.working.map(&:label), "Open seat, direct, L2, × open FTE 0.5"
    assert_not figure.overloaded
  end

  should "follow a tenant's own costs and weights" do
    params = { "fixed_cost" => { "default" => "0", "by_level" => { "3" => "0.2" } }, "per_report" => { "direct" => "0.5", "skip" => "0", "deeper" => "0" },
               "report_weight" => { "default" => "2", "by_level" => {} } }

    assert_equal({ "c" => 1r, "d" => 0r }, costs(price("a", params:)))
    assert_equal Rational("0.2"), -price("a", params:).working.second.amount
  end

  should "charge nothing to a seat that manages nobody" do
    assert_equal [ "Base at L3", "Units" ], price("d").working.map(&:label)
    assert_empty costs(price("d"))
  end

  should "count a report whose level resolves to none at the default weight, and say so" do
    @levels.delete("b")

    assert_equal Rational("0.1"), costs(price("m"))["b"]
    assert_includes price("m").working.map(&:label), "Report, direct, level unknown, default weight"
  end

  should "floor a manager whose reports cost more than the base at zero, and say by how much they are over" do
    @people += %w[r1 r2 r3 r4].map { member(it, "team", manager_id: "b") }
    @levels.merge!(%w[r1 r2 r3 r4].to_h { [ it, 1 ] })
    figure = price("b")

    assert_equal 0r, figure.amount
    assert figure.overloaded
    assert_equal Rational("0.3"), figure.excess
    assert_equal "Floored at zero: managing costs more than the base", figure.working[-2].label
  end

  should "take the manager's whole cost before scaling by share and FTE, saying when either wasn't recorded" do
    whole = price("m").amount
    figure = price("m", allocation: Rational(1, 2), fte: Rational(4, 5))

    assert_equal whole * Rational(2, 5), figure.amount
    assert_equal [ "× share of the seat in this place", "× FTE" ], figure.working[-3..-2].map(&:label)
    labels = price("m", allocation: Rational(1, 2), allocation_known: false, fte: 1r, fte_known: false).working.map(&:label)
    assert_includes labels, "× share not recorded, split from what the other places leave"
    assert_includes labels, "× FTE not recorded, counted as 1"
  end

  should "attribute an open seat to the one filled manager seat in the nearest unit that holds one" do
    assert_includes costs(price("m")).keys, "p"
    assert_empty price("m").notes
  end

  should "attribute an open seat to the vacant manager position in its unit, with its unmanaged people, and leave out those another manager holds" do
    figure = price("v", fte: Rational(1, 2))

    assert_equal %w[e f w].sort, costs(figure).keys.sort
    assert_equal [ "Base at L5", "Fixed cost of managing at L5" ], figure.working.first(2).map(&:label)
    assert_includes figure.working.map(&:label), "× open FTE"
  end

  should "attribute an open seat to nobody when the nearest unit with a manager seat holds two" do
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

    assert_equal [ "unattributed_several_managers" ], graph.notes_for("q")
    assert_not(%w[m a c].any? { graph.span(it).map(&:id).include?("q") })
  end

  should "attribute an open seat to nobody when no unit up the tree holds a manager seat" do
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

    assert_equal [ "unattributed_no_manager" ], graph.notes_for("lone")
    assert_not(%w[m a c v].any? { graph.span(it).map(&:id).include?("lone") })
  end

  should "make a seat whose role a tenant names a manager, so open seats, vacant managers and unmanaged people below it count against it" do
    @positions << position("lead", "root")
    @open["lead"] = 1r
    @levels["lead"] = 4
    @roles["lead"] = [ "em" ]
    params = { "manager_role_ids" => [ "EM" ] }

    working = price("lead", params:).working
    assert_equal %w[lone v m], working.select { it.label.include?("direct") }.map(&:subject_id)
    assert_equal %w[e f w].sort, (working.select { it.label.include?("skip") }.map(&:subject_id) - %w[a b g p]).sort
    assert_equal [ "Base at L4", "Units" ], price("lead").working.map(&:label)
  end

  should "send a line to a position to the one person in it, though some of its FTE stands open" do
    @positions << position("pair", "squad")
    @open["pair"] = 1r
    @people += [ member("o", "squad", position_id: "pair"), member("r", "squad", manager_position_id: "pair") ]
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

    assert_equal [ "r" ], graph.span("o").map(&:id)
    assert_not graph.manager?("pair")
  end

  should "send a line to a position two people share to neither, leaving the report unmanaged" do
    @positions << position("pair", "squad")
    @people += [ member("o1", "squad", position_id: "pair"), member("o2", "squad", position_id: "pair"),
                 member("r", "squad", manager_position_id: "pair") ]
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

    assert_not(%w[o1 o2 pair a c m].any? { graph.span(it).map(&:id).include?("r") })
    assert_not(%w[o1 o2 pair].any? { graph.manager?(it) })
  end

  should "attach an unmanaged person through their largest share, reading an unrecorded one as what the others leave" do
    [ nil, 0.8 ].each do |studio_share|
      memberships = [ Baseline::Membership.new(unit_id: "studio", allocation: studio_share, role: nil),
                      Baseline::Membership.new(unit_id: "team", allocation: 0.2, role: nil) ]
      @people = @people.reject { it.id == "h" } << member("h", "studio").with(memberships:)
      graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

      assert_includes graph.span("v").map(&:id), "h", "studio share #{studio_share.inspect}"
    end
  end

  should "send a line to a closed position to nobody, though someone still fills it" do
    @people += [ member("o", "squad", position_id: "gone"), member("r", "squad", manager_position_id: "gone") ]
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

    assert_not graph.manager?("o")
    assert_empty graph.span("o")
  end

  should "never make the head of the tree a report of a vacant manager seat beneath them" do
    @people << member("ceo", "root")
    @people.map! { it.id == "m" ? it.with(manager_id: "ceo") : it }
    @positions << position("vp", "root")
    @open["vp"] = 1r
    @roles["vp"] = [ "em" ]
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [ "em" ])

    assert_includes graph.span("ceo").map(&:id), "vp"
    assert_not_includes graph.span("vp").map(&:id), "ceo"
  end

  should "never make someone with no line who owns a vacant manager seat's unit, or a unit above it, a report of the seat" do
    @people += [ member("lead", "studio"), member("boss", "studio") ]
    @units.map! { %w[studio root].include?(it.id) ? it.with(owner_ids: [ { "studio" => "lead", "root" => "boss" }[it.id] ]) : it }
    span = Units::Graph.new(map:, facts:, manager_role_ids: []).span("v").map(&:id)

    assert_not_includes span, "lead"
    assert_not_includes span, "boss"
    assert_includes span, "e"
  end

  should "never count a leaver as a report, and pass their reports to the position backfilling them, or to nobody" do
    @people.map! { it.id == "c" ? it.with(departure: { leaves_in_id: "s1", position_id: "v" }) : it }
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

    assert_not graph.manager?("c")
    assert_includes graph.span("v").map(&:id), "d"
    assert_not(graph.span("a").map(&:id).include?("c") || graph.span("m").map(&:id).include?("d"))

    @facts = nil
    @people.map! { it.id == "c" ? it.with(departure: { leaves_in_id: "s1", position_id: nil }) : it }
    assert_not(Units::Graph.new(map:, facts:, manager_role_ids: []).span("m").map(&:id).include?("d"))
  end

  should "pass a line to a position only a leaver fills to the position backfilling them" do
    @positions << position("lead", "squad")
    @people.map! do
      case it.id
      when "c" then member("c", "squad", manager_id: "a", position_id: "lead", departure: { leaves_in_id: "s1", position_id: "v" })
      when "d" then member("d", "squad", manager_position_id: "lead")
      else it
      end
    end
    graph = Units::Graph.new(map:, facts:, manager_role_ids: [])

    assert_includes graph.span("v").map(&:id), "d"
    assert_not graph.manager?("lead")

    @open["lead"] = Rational(1, 2)
    @facts = nil
    part_filled = Units::Graph.new(map:, facts:, manager_role_ids: [])
    assert_includes part_filled.span("v").map(&:id), "d"
    assert_not part_filled.manager?("lead")
  end

  should "price a seat whose level resolves to none as nothing, with a reason" do
    figure = price("x", ordinal: nil)

    assert_equal "no_level", figure.reason
    assert_equal 0r, figure.amount
  end
end
