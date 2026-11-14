# frozen_string_literal: true

require "test_helper"

class OrgGraph::DateComparisonTest < ActiveSupport::TestCase
  include OrgGraphFixture

  TODAY = Date.new(2026, 11, 13)
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    travel_to Time.zone.parse("2026-10-01 09:00")
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    as_tenant do
      user = create(:user)
      @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def window(from, to = nil, by = nil) = OrgGraph::DateComparison.window(from:, to:, by:, today: TODAY)

  def compare(from, to = nil, by = nil)
    as_tenant { OrgGraph::DateComparison.new(context: @context, window: window(from, to, by), today: TODAY) }
  end

  def unit(key) = as_tenant { OrgUnit.find(@org[key]) }

  def lines(comparison, key) = comparison.people_changes(unit(key)).map { "#{it.name} #{it.text}" }

  # Uma joins Checkout, Ada moves to Checkout, Cyril leaves, Platform is
  # renamed, Insights is created under Engineering and Payments moves to it,
  # all in October and November.
  def reorganise
    insights = SecureRandom.uuid_v7
    as_tenant do
      @uma = create(:person, tenant: @tenant, name: "Uma Reyes")
      @handler.record_person(@uma.id, **ESPALIA, effective_on: "2026-10-01", employment_status: "pending")
      @handler.join(@uma.id, **ESPALIA, effective_on: "2026-11-05")
      @handler.set_membership(@uma.id, @org[:checkout], **ESPALIA, effective_on: "2026-11-05", allocation: 1.0)
      @handler.move_membership(@org[:ada].id, @org[:platform], @org[:checkout], effective_on: "2026-10-20")
      @handler.leave(@org[:cyril].id, **ESPALIA, effective_on: "2026-10-31")
      @structure.rename_unit(@org[:platform], "Core Platform", effective_on: "2026-10-10")
      @structure.create_unit(insights, "Insights", level_id: @org[:team], parent_id: @org[:engineering], effective_on: "2026-10-12")
      @structure.move_unit(@org[:payments], insights, effective_on: "2026-10-14")
    end
    insights
  end

  should "read no window when no date is picked, and today when no end date is" do
    assert_nil window("")
    assert_equal [ Date.new(2026, 10, 1), TODAY, :effective ], window("2026-10-01").to_h.values_at(:from, :to, :by)
    assert_equal :learned, window("2026-10-01", "2026-11-01", "learned").by
    assert_equal :effective, window("2026-10-01", nil, "sideways").by
  end

  should "refuse a date it can't read, a window with no day in it and a day after today, with a message" do
    { [ "1 Oct" ] => "Pick a date to compare with.",
      [ "2026-10-01", "soon" ] => "Pick an end date, or leave it as today.",
      [ "2026-10-05", "2026-10-01" ] => "Pick an end date after the date you compare with.",
      [ "2026-10-05", "2026-10-05" ] => "Pick an end date after the date you compare with.",
      [ "1" * 200 ] => "Pick a date to compare with.",
      [ "2026-10-01", "2026-11-14" ] => "Pick dates no later than today." }.each do |args, message|
      error = assert_raises(OrgGraph::DateComparison::InvalidWindow) { window(*args) }
      assert_equal message, error.message
    end
  end

  should "mark each unit new, renamed or moved in the window, and count the changes" do
    insights = reorganise
    travel_to TODAY
    comparison = compare("2026-10-01")

    assert_equal [ "was Platform" ], comparison.unit_marks(unit(:platform))
    assert_equal [ "new" ], as_tenant { comparison.unit_marks(OrgUnit.find(insights)) }
    assert_equal [ "moved from Checkout" ], comparison.unit_marks(unit(:payments))
    assert_empty comparison.unit_marks(unit(:engineering))
    assert_equal({ "Joined" => 1, "Left" => 1, "Moved" => 1, "New units" => 1, "Renamed" => 1, "Units moved" => 1,
                   "Retired" => 0, "Succeeded" => 0 }, comparison.counts.to_h)
    assert_equal "Since 1 Oct", comparison.window_label
    assert_equal({ from: "2026-10-01", to: "2026-11-13", by: "effective" }, comparison.params)
  end

  should "list who joined, left and moved through each unit, by the date each took effect" do
    reorganise
    travel_to TODAY
    comparison = compare("2026-10-01")

    assert_equal [ "Ada Quill moved to Checkout 20 Oct" ], lines(comparison, :platform)
    assert_equal [ "Ada Quill moved in from Core Platform 20 Oct", "Cyril Moss left 31 Oct", "Uma Reyes joined 5 Nov" ],
                 lines(comparison, :checkout).sort
  end

  should "read a window between two dates, which leaves out what came after it" do
    reorganise
    travel_to TODAY
    comparison = compare("2026-10-01", "2026-10-25")

    assert_equal "1 Oct to 25 Oct", comparison.window_label
    assert_equal [ "Ada Quill moved in from Core Platform 20 Oct" ], lines(comparison, :checkout)
  end

  should "say a leaver left only the units the leaving ended, after they return to another" do
    reorganise
    as_tenant do
      @handler.return_to_work(@org[:cyril].id, **ESPALIA, effective_on: "2026-11-06")
      @handler.set_membership(@org[:cyril].id, @org[:platform], **ESPALIA, effective_on: "2026-11-06", allocation: 1.0)
    end
    travel_to TODAY
    comparison = compare("2026-10-01")

    assert_includes lines(comparison, :checkout), "Cyril Moss left 31 Oct"
    assert_equal [ "Cyril Moss joined 6 Nov" ], lines(comparison, :platform).grep(/Cyril/)
  end

  should "name a forgotten person as a former member" do
    reorganise
    travel_to TODAY
    as_tenant { @org[:cyril].update!(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

    assert_includes lines(compare("2026-10-01"), :checkout), "Former member left 31 Oct"
  end

  should "list a unit retired in the window with its successor" do
    reorganise
    travel_to TODAY
    as_tenant do
      @structure.apply_succession(SecureRandom.uuid_v7, predecessor_ids: [ @org[:payments] ],
                                                        successor_ids: [ @org[:checkout] ], effective_on: "2026-11-02")
    end
    comparison = compare("2026-10-01")

    assert_equal [ [ "Payments", Date.new(2026, 11, 2), [ "Checkout" ], false ] ], comparison.retirements.map(&:deconstruct)
    assert_includes comparison.unit_marks(unit(:checkout)), "succeeds Payments"
  end

  should "by learned date, count a change withdrawn in the window apart from the changes still believed" do
    as_tenant { @structure.rename_unit(@org[:platform], "Core", effective_on: "2026-10-07") }
    travel_to Time.zone.parse("2026-11-10 09:00")
    as_tenant { OrgGraph::ChangeBackHandler.new(actor: OrgGraph::Authorization::SYSTEM).change_back(OrgUnitActivity.for_unit(@org[:platform]).first) }
    travel_to TODAY

    counts = compare("2026-11-01", nil, "learned").counts.to_h
    assert_equal [ 0, 1 ], counts.values_at("Renamed", "Withdrawn")
    assert_not_includes compare("2026-10-01").counts.to_h, "Withdrawn"
  end

  should "by learned date, show a backdated change learned in the window with the day it took effect" do
    travel_to Time.zone.parse("2026-11-10 09:00")
    as_tenant { @handler.move_membership(@org[:dot].id, @org[:payments], @org[:platform], effective_on: "2026-09-15") }
    travel_to TODAY

    assert_empty lines(compare("2026-11-01"), :platform)
    comparison = compare("2026-11-01", nil, "learned")
    assert comparison.learned?
    assert_equal [ "Dot Fennick moved in from Payments 15 Sep, learned 10 Nov" ], lines(comparison, :platform)
  end
end
