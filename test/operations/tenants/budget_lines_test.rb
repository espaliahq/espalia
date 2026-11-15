# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::BudgetLinesTest < ActiveSupport::TestCase
  LINE = { starts_on: "2027-01-01", ends_on: "2027-12-31", origin: "new", approved_on: "2026-10-01",
           amount: "120000", currency: "AUD", period: "year", head_count: "1" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Admin"))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      @planner = create(:tenant_user, tenant: @tenant, role: :member, team_planner: true, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true, person: create(:person, tenant: @tenant))
      @role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @other_role = create(:framework_role, tenant: @tenant, name: "Designer")
      @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, code: "E2", title: "Engineer II")
    end
  end

  def context(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::Tenants::#{operation}".constantize.call(context: context(as), params:) }
  end

  def add(**params) = call(:AddBudgetLine, **LINE, level_id: @level.level_id, location: "Fixtureland", **params)

  should "add a line, list it, change it and remove it" do
    added = add

    assert_equal [ "Software Engineer", "E2 Engineer II", "Fixtureland" ], added.values_at(:role, :level_name, :location)
    assert_equal [ "120000.00", "AUD", "year", "1.00" ], added.values_at(:amount, :currency, :period, :head_count)
    assert_equal [ "new", "2026-10-01", "Ada Admin" ], added.values_at(:origin, :approved_on, :updated_by)
    assert_equal [ added[:budget_line_id] ], call(:BudgetLines)[:budget_lines].pluck(:budget_line_id)

    changed = call(:ChangeBudgetLine, budget_line_id: added[:budget_line_id], **LINE.except(:approved_on), origin: "replacement",
                                      amount: "9000.5", currency: "nzd", period: "month", role_id: @role.role_id)
    assert_equal [ "9000.50", "NZD", "month", "replacement" ], changed.values_at(:amount, :currency, :period, :origin)
    assert_equal [ @role.role_id, nil, nil, nil ], changed.values_at(:role_id, :level_id, :approved_on, :location)

    removed = call(:RemoveBudgetLine, budget_line_id: added[:budget_line_id])
    assert_equal "Software Engineer", removed[:role]
    assert_empty call(:BudgetLines)[:budget_lines]
  end

  should "keep a head count with no amount as no amount, never zero" do
    added = add(amount: nil, currency: nil, period: nil, head_count: "2")

    assert_equal [ nil, nil, nil, "2.00" ], added.values_at(:amount, :currency, :period, :head_count)
  end

  should "hold a line for any role, and read one line by id" do
    added = add(level_id: nil, location: nil)
    add(starts_on: "2028-01-01", ends_on: "2028-12-31")

    line = call(:BudgetLines, budget_line_id: added[:budget_line_id])[:budget_lines].sole
    assert_equal [ nil, nil, nil, nil ], line.values_at(:role_id, :level_id, :role, :location)
  end

  should "refuse a level of another role, and a role or level outside the framework" do
    refusals = [
      -> { add(role_id: @other_role.role_id) },
      -> { add(level_id: SecureRandom.uuid_v7) },
      -> { add(level_id: nil, role_id: SecureRandom.uuid_v7) }
    ].map { assert_raises(Operations::Base::ParameterError, &it).message }

    assert_equal [ "That level belongs to another role", "There is no such level in the framework",
                   "There is no such role in the framework" ], refusals
  end

  should "keep a level that has left the framework while a change gives it again" do
    added = add
    ActsAsTenant.with_tenant(@tenant) { @level.destroy! }

    changed = call(:ChangeBudgetLine, budget_line_id: added[:budget_line_id], **LINE, head_count: "3", level_id: added[:level_id])
    assert_equal [ @level.level_id, "E2 Engineer II", "3.00" ], changed.values_at(:level_id, :level_name, :head_count)

    error = assert_raises(Operations::Base::ParameterError) { add(level_id: added[:level_id]) }
    assert_equal "There is no such level in the framework", error.message
  end

  should "never repeat an amount or a head count in a refusal" do
    errors = [
      -> { add(amount: "99999.999") },
      -> { add(head_count: "8888.888") },
      -> { add(amount: "77777", currency: "DOLLARS") },
      -> { add(amount: "66666", starts_on: "2028-01-01") },
      -> { add(amount: nil, head_count: nil) }
    ].map { assert_raises(Operations::Base::ParameterError, &it).message }

    errors.each { |message| assert_no_match(/999|888|777|666|120/, message) }
    assert_equal "A budget line can't end before it starts", errors[3]
    assert_equal "provide at least one of: amount, head_count", errors[4]
  end

  should "refuse a comma, which the page strips only from a grouped figure" do
    [ "52,50", "1,2,3", "120,000" ].each do |amount|
      error = assert_raises(Operations::Base::ParameterError) { add(amount:) }
      assert_equal "amount must be a number with at most two decimal places", error.message
    end
  end

  should "refuse an amount with no currency or period, and an approval date for a seat already held" do
    refusals = [
      -> { add(currency: nil) },
      -> { add(period: nil) },
      -> { add(origin: "existing") }
    ].map { assert_raises(Operations::Base::ParameterError, &it).message }

    assert_equal [ "An amount needs a currency", "An amount needs a period, year or month",
                   "approved_on applies to a new position only" ], refusals
  end

  should "refuse a date that isn't one" do
    error = assert_raises(Operations::Base::ParameterError) { add(ends_on: "2027-02-30") }

    assert_equal "ends_on must be a date, YYYY-MM-DD", error.message
  end

  should "refuse a line this tenant doesn't hold" do
    assert_raises(Operations::Base::ParameterError) { call(:RemoveBudgetLine, budget_line_id: SecureRandom.uuid_v7) }
  end

  should "leave the budget to tenant admins, refusing a planner, an editor and a member with no detail" do
    added = add

    [ @member, @planner, @editor ].each do |account|
      [
        -> { call(:BudgetLines, as: account) },
        -> { add(as: account) },
        -> { call(:ChangeBudgetLine, as: account, budget_line_id: added[:budget_line_id], **LINE) },
        -> { call(:RemoveBudgetLine, as: account, budget_line_id: added[:budget_line_id]) }
      ].each { assert_no_match(/120000|Software|Fixtureland/, assert_raises(Pundit::NotAuthorizedError, &it).message) }
    end
    assert_equal 1, ActsAsTenant.with_tenant(@tenant) { BudgetLine.count }
  end

  should "not reach another tenant's lines" do
    added = add
    other = create(:tenant)
    outsider = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }

    ActsAsTenant.with_tenant(other) do
      assert_empty Operations::Tenants::BudgetLines.call(context: context(outsider), params: {})[:budget_lines]
      assert_raises(Operations::Base::ParameterError) do
        Operations::Tenants::RemoveBudgetLine.call(context: context(outsider), params: { budget_line_id: added[:budget_line_id] })
      end
    end
  end
end
