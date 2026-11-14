# frozen_string_literal: true

require "test_helper"

class BudgetLineTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
    @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, code: "E2", title: "Engineer II")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def line(**attrs)
    BudgetLine.new(starts_on: "2027-01-01", ends_on: "2027-12-31", origin: "new",
                   amount: 120_000, currency: "AUD", period: "year", **attrs)
  end

  should "keep an amount in its own currency and period, as entered" do
    saved = line(currency: " nzd ", amount: "98000.5", period: "month")
    saved.save!

    assert_equal [ "NZD", "month", "98000.50" ], [ saved.currency, saved.period, saved.figure(:amount) ]
  end

  should "hold a head count with no amount, which reads as no amount, never zero" do
    saved = line(amount: nil, head_count: 2)
    saved.save!

    assert_nil saved.amount
    assert_nil saved.figure(:amount)
    assert_nil saved.currency, "a line with no amount keeps no currency"
    assert_equal "2.00", saved.figure(:head_count)
  end

  should "refuse a line with neither amount nor head count" do
    blank = line(amount: nil)

    assert_not blank.valid?
    assert_includes blank.errors[:base], "A budget line needs an amount, a head count or both"
  end

  should "refuse an amount with no currency or period, a negative amount and a head count of zero" do
    assert_not line(currency: nil).valid?
    assert_not line(currency: "XYZ").valid?
    assert_not line(period: "hour").valid?
    assert_not line(amount: -1).valid?
    assert_not line(head_count: 0).valid?
  end

  should "refuse a period that ends before it starts, and an origin it doesn't know" do
    backwards = line(starts_on: "2027-06-01", ends_on: "2027-05-31")

    assert_not backwards.valid?
    assert_includes backwards.errors[:base], "A budget line can't end before it starts"
    assert_not line(origin: "contractor").valid?
  end

  should "keep an approval date only on a new position" do
    assert_equal Date.new(2026, 10, 1), line(approved_on: "2026-10-01").tap(&:valid?).approved_on
    assert_nil line(origin: "replacement", approved_on: "2026-10-01").tap(&:valid?).approved_on
  end

  should "copy its level's names, so the line still reads once the level leaves" do
    saved = line.tap { it.take_level(@level) }

    assert_equal [ @role.role_id, @level.level_id ], saved.values_at(:role_id, :level_id)
    assert_equal "Software Engineer, E2 Engineer II", saved.role_label
    assert_nil line.role_label
  end

  should "squeeze the location and cost centre, reading blank as any" do
    saved = line(location: "  New   Zealand ", cost_centre: nil)
    saved.save!

    assert_equal [ "New Zealand", "" ], [ saved.location, saved.cost_centre ]
  end
end
