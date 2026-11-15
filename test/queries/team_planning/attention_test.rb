# frozen_string_literal: true

require "test_helper"

class TeamPlanning::AttentionTest < ActiveSupport::TestCase
  B = TeamPlanning::Baseline
  LEVEL, ROOT, LIVE, RETIRED, GONE, PERSON = Array.new(6) { SecureRandom.uuid_v7 }

  def map(**overrides)
    B::Map.new(base_on: Date.new(2027, 1, 1), known_on: Date.new(2027, 1, 1), units: [ unit(ROOT, nil), unit(LIVE, ROOT) ],
               retired_units: [ unit(RETIRED, ROOT) ], people: [], unassigned_ids: [], positions: [], names: {}, rules: nil,
               **overrides)
  end

  # PERSON heads the tree, so a test on another check isn't also told they have no manager.
  def unit(id, parent_id) = B::Unit.new(id:, name: "Unit", parent_id:, level_id: LEVEL, owner_ids: parent_id ? [] : [ PERSON ])

  def change(kind, subject_id, **end_state) = kind.new(data: { plan_id: ROOT, scenario_id: ROOT, subject_id:, set_by_id: PERSON, **end_state })

  def member(id = PERSON, places: [ [ LIVE, 1 ] ], **line)
    B::Member.new(id:, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                  employment_type: nil, memberships: places.map { |unit_id, allocation| B::Membership.new(unit_id:, allocation:, role: nil) },
                  **line)
  end

  def reasons(map, changes = {}) = TeamPlanning::Attention.new(map, changes).call.map(&:reason)

  should "say which unit a succession lost, and nothing for one whose predecessor retired as it should" do
    fits = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ RETIRED ], successor_ids: [ LIVE ])
    broken = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ GONE ], successor_ids: [ RETIRED ])

    assert_empty reasons(map(successions: [ fits ]))
    assert_equal [ "It carries on from a unit no longer in this scenario", "It is carried on by a retired unit" ],
                 reasons(map(successions: [ broken ]))
  end

  should "mark a succession whose predecessor is live again" do
    assert_equal [ "It carries on from a unit that is still live" ],
                 reasons(map(successions: [ B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [ LIVE ], successor_ids: [ ROOT ]) ]))
  end

  should "mark someone once for each reason, however many of their places it covers" do
    places = [ RETIRED, RETIRED ].map { B::Membership.new(unit_id: it, allocation: 0.5, role: nil) }
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil, memberships: places + [ B::Membership.new(unit_id: GONE, allocation: 0.5, role: nil) ])

    assert_equal [ "Placed in a retired unit", "Placed in a unit no longer in this scenario" ], reasons(map(people: [ person ]))
  end

  should "list one subject's reasons in order, whatever order their places come in" do
    assert_equal [ "Placed in a retired unit", "Placed in a unit no longer in this scenario" ],
                 reasons(map(people: [ member(places: [ [ GONE, 0.5 ], [ RETIRED, 0.5 ] ]) ]))
  end

  should "tell a retired unit from one no longer in the scenario" do
    units = [ unit(ROOT, nil), unit(LIVE, GONE) ]
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil, memberships: [ B::Membership.new(unit_id: GONE, allocation: 1, role: nil) ])

    assert_equal [ "Placed in a unit no longer in this scenario", "Its parent is a unit no longer in this scenario" ],
                 reasons(map(units:, people: [ person ]))
  end

  should "name the change that broke a subject no scenario changed, and none when nothing explains it" do
    retired = change(TeamPlanning::Events::UnitRetired, RETIRED, name: "Unit", parent_id: ROOT, level_id: LEVEL)
    orphan = unit(SecureRandom.uuid_v7, RETIRED)

    assert_equal [ retired ], TeamPlanning::Attention.new(map(units: [ unit(ROOT, nil), orphan ]), { retired.key => retired }).call.map(&:change)
    assert_equal [ nil ], TeamPlanning::Attention.new(map(units: [ unit(ROOT, nil), orphan ]), {}).call.map(&:change)
  end

  should "name the later of two retirements behind one reason" do
    other = SecureRandom.uuid_v7
    first, last = [ RETIRED, other ].map { change(TeamPlanning::Events::UnitRetired, it, name: "Unit", parent_id: ROOT, level_id: LEVEL) }
    changes = { first.key => first, last.key => last }
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil,
                           memberships: [ RETIRED, other ].map { B::Membership.new(unit_id: it, allocation: 0.5, role: nil) })
    succession = B::Succession.new(id: SecureRandom.uuid_v7, predecessor_ids: [], successor_ids: [ RETIRED, other ])
    retired_units = [ unit(RETIRED, ROOT), unit(other, ROOT) ]

    assert_equal [ last, last ],
                 TeamPlanning::Attention.new(map(retired_units:, people: [ person ], successions: [ succession ]), changes).call.map(&:change)
  end

  should "read a small overfill at the precision open FTE keeps" do
    position = B::Position.new(id: SecureRandom.uuid_v7, role_id: nil, level_id: LEVEL, unit_id: LIVE, fte: 1.0, basis: "new",
                               role_name: nil, level_name: nil)
    person = B::Member.new(id: PERSON, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: 1,
                           employment_type: nil,
                           memberships: [ B::Membership.new(unit_id: LIVE, allocation: 1.004, role: nil, position_id: position.id) ])

    assert_equal [ "Overfilled by 0.004 FTE", "Over-allocated, at 100.4%" ], reasons(map(positions: [ position ], people: [ person ]))
  end

  should "read why someone off the map can't be placed" do
    assert_equal [ "Placed, but has left" ], reasons(map(unresolved: [ B::Unresolved.new(person_id: PERSON, why: B::Unresolved::LEFT) ]))
  end
  should "mark someone placed nowhere, over or under 100%, and never read an unknown total as under" do
    assert_equal [ "Placed nowhere" ], reasons(map(people: [ member(places: []) ]))
    assert_equal [ "Under-allocated, at 50%" ], reasons(map(people: [ member(places: [ [ LIVE, 0.5 ] ]) ]))
    assert_equal [ "Over-allocated, at 150%" ], reasons(map(people: [ member(places: [ [ LIVE, 1 ], [ ROOT, 0.5 ] ]) ]))
    assert_empty reasons(map(people: [ member(places: [ [ LIVE, 0.5 ], [ ROOT, nil ] ]) ]))
  end

  should "name the retirement that left someone under-allocated" do
    retired = change(TeamPlanning::Events::UnitRetired, RETIRED, name: "Unit", parent_id: ROOT, level_id: LEVEL)
    items = TeamPlanning::Attention.new(map(people: [ member(places: [ [ LIVE, 0.5 ], [ RETIRED, 0.5 ] ]) ]), { retired.key => retired }).call

    assert_equal [ [ "Placed in a retired unit", retired ], [ "Under-allocated, at 50%", retired ] ], items.map { [ it.reason, it.change ] }
  end

  should "mark someone the Org Graph has had leave once, placed or not, unless the plan has them leave" do
    leaver = member
    assert_equal [ "Placed, but has since left" ], TeamPlanning::Attention.new(map(people: [ leaver ]), {}, left_ids: [ PERSON ]).call.map(&:reason)
    assert_equal [ "Has since left" ], TeamPlanning::Attention.new(map(people: [ member(places: []) ]), {}, left_ids: [ PERSON ]).call.map(&:reason)
    assert_equal [ "Placed, but has since left" ],
                 TeamPlanning::Attention.new(map(people: [ member(places: [ [ LIVE, 0.5 ] ]) ]), {}, left_ids: [ PERSON ]).call.map(&:reason)

    leaving = leaver.with(departure: { leaves_in_id: ROOT, position_id: nil })
    assert_empty TeamPlanning::Attention.new(map(people: [ leaving ]), {}, left_ids: [ PERSON ]).call
  end

  should "mark someone whose manager the Org Graph has had leave, even when the plan has the manager leave" do
    report = member(SecureRandom.uuid_v7, manager_id: PERSON)
    assert_equal [ [ PERSON, "Placed, but has since left" ], [ report.id, "Their manager has since left" ] ],
                 TeamPlanning::Attention.new(map(people: [ member, report ]), {}, left_ids: [ PERSON ]).call.map { [ it.subject_id, it.reason ] }

    leaving = member.with(departure: { leaves_in_id: ROOT, position_id: nil })
    assert_equal [ [ report.id, "Their manager has since left" ] ],
                 TeamPlanning::Attention.new(map(people: [ leaving, report ]), {}, left_ids: [ PERSON ]).call.map { [ it.subject_id, it.reason ] }
  end

  should "mark a contributor with no manager, but not the head of the tree" do
    other = SecureRandom.uuid_v7
    assert_equal [ [ other, "reporting_line", "Has no manager" ] ],
                 TeamPlanning::Attention.new(map(people: [ member, member(other) ]), {}).call.map { it.to_h.values_at(:subject_id, :facet, :reason) }
  end

  should "name the move that took someone off the head of the tree" do
    head, other = Array.new(2) { SecureRandom.uuid_v7 }
    units = [ unit(ROOT, nil), unit(LIVE, ROOT), B::Unit.new(id: head, name: "Unit", parent_id: ROOT, level_id: LEVEL, owner_ids: [ other ]) ]
    moved = change(TeamPlanning::Events::UnitSet, head, name: "Unit", parent_id: ROOT, level_id: LEVEL)

    assert_equal [ [ other, "Has no manager", moved ] ],
                 TeamPlanning::Attention.new(map(units:, people: [ member, member(other) ]), { moved.key => moved }).call.map { [ it.subject_id, it.reason, it.change ] }
  end

  should "count a manager who owns the unit above as sharing one, and mark one who shares none" do
    team, far = Array.new(2) { SecureRandom.uuid_v7 }
    units = [ unit(ROOT, nil), unit(LIVE, ROOT), unit(team, LIVE), unit(far, ROOT) ]
    lead = member(SecureRandom.uuid_v7, places: [ [ LIVE, 1 ] ], manager_id: PERSON)
    report = member(SecureRandom.uuid_v7, places: [ [ team, 1 ] ], manager_id: lead.id)
    stray = member(SecureRandom.uuid_v7, places: [ [ far, 1 ] ], manager_id: lead.id)

    assert_equal [ "Their manager shares no unit with them" ], reasons(map(units:, people: [ member, lead, report, stray ]))
  end

  should "name the manager's own change when it is the one that moved them away" do
    far = SecureRandom.uuid_v7
    lead = member(SecureRandom.uuid_v7, places: [ [ far, 1 ] ], manager_id: PERSON)
    report = member(SecureRandom.uuid_v7, manager_id: lead.id)
    line = change(TeamPlanning::Events::ReportingLineSet, report.id, manager_id: lead.id)
    moved = change(TeamPlanning::Events::AssignmentSet, lead.id, memberships: [])

    items = TeamPlanning::Attention.new(map(units: [ unit(ROOT, nil), unit(LIVE, ROOT), unit(far, ROOT) ], people: [ member, lead, report ]),
                                        { line.key => line, moved.key => moved }).call
    assert_equal [ [ report.id, moved ] ], items.select { it.facet == "reporting_line" }.map { [ it.subject_id, it.change ] }
  end

  should "name the unit change that moved a report's team away from their manager" do
    team, far = Array.new(2) { SecureRandom.uuid_v7 }
    lead = member(SecureRandom.uuid_v7, manager_id: PERSON)
    report = member(SecureRandom.uuid_v7, places: [ [ team, 1 ] ], manager_id: lead.id)
    moved = change(TeamPlanning::Events::UnitSet, team, name: "Unit", parent_id: far, level_id: LEVEL)

    items = TeamPlanning::Attention.new(map(units: [ unit(ROOT, nil), unit(LIVE, ROOT), unit(far, ROOT), unit(team, far) ], people: [ member, lead, report ]),
                                        { moved.key => moved }).call
    assert_equal [ [ report.id, moved ] ], items.select { it.facet == "reporting_line" }.map { [ it.subject_id, it.change ] }
  end

  should "name the manager's departure, not a later rename of the report's unit" do
    report = member(SecureRandom.uuid_v7, manager_id: PERSON)
    left = change(TeamPlanning::Events::DepartureSet, PERSON, leaves_in_id: ROOT)
    renamed = change(TeamPlanning::Events::UnitSet, LIVE, name: "Renamed", parent_id: ROOT, level_id: LEVEL)

    items = TeamPlanning::Attention.new(map(people: [ member.with(departure: { leaves_in_id: ROOT, position_id: nil }), report ]),
                                        { left.key => left, renamed.key => renamed }, left_ids: [ PERSON ]).call
    assert_equal [ [ report.id, left ] ], items.map { [ it.subject_id, it.change ] }
  end

  should "name the move of the position a manager sits in when it parts them from a report" do
    far = SecureRandom.uuid_v7
    seat = B::Position.new(id: SecureRandom.uuid_v7, role_id: nil, level_id: LEVEL, unit_id: far, fte: 1.0, basis: "new",
                           role_name: nil, level_name: nil)
    lead = member(SecureRandom.uuid_v7, places: [], manager_id: PERSON)
      .then { it.with(memberships: [ B::Membership.new(unit_id: far, allocation: 1, role: nil, position_id: seat.id) ]) }
    report = member(SecureRandom.uuid_v7, manager_id: lead.id)
    moved = change(TeamPlanning::Events::PositionSet, seat.id, role_id: nil, level_id: LEVEL, unit_id: far, fte: 1.0, basis: "new")

    items = TeamPlanning::Attention.new(map(units: [ unit(ROOT, nil), unit(LIVE, ROOT), unit(far, ROOT) ], positions: [ seat ],
                                            people: [ member, lead, report ]), { moved.key => moved }).call
    assert_equal [ [ report.id, moved ] ], items.select { it.facet == "reporting_line" }.map { [ it.subject_id, it.change ] }
  end

  should "mark a manager or a manager's position that is no longer in the scenario" do
    position = B::Position.new(id: SecureRandom.uuid_v7, role_id: nil, level_id: LEVEL, unit_id: ROOT, fte: 1.0, basis: "new",
                               role_name: nil, level_name: nil)
    under_seat = member(SecureRandom.uuid_v7, manager_position_id: position.id)
    elsewhere = member(SecureRandom.uuid_v7, places: [ [ ROOT, 1 ] ], manager_position_id: position.id)
    assert_empty reasons(map(positions: [ position ], people: [ member, under_seat, elsewhere ]))

    away = position.with(unit_id: LIVE)
    assert_equal [ "Their manager's position shares no unit with them" ], reasons(map(positions: [ away ], people: [ member, elsewhere ]))
    assert_equal [ "In a retired unit" ], reasons(map(positions: [ position.with(unit_id: RETIRED) ], people: [ member, elsewhere ]))

    orphans = [ member(SecureRandom.uuid_v7, manager_id: SecureRandom.uuid_v7), member(SecureRandom.uuid_v7, manager_position_id: SecureRandom.uuid_v7) ]
    assert_equal [ "Their manager is no longer in this scenario", "Their manager's position is no longer in this scenario" ].sort,
                 reasons(map(people: [ member, *orphans ])).sort
  end
end
