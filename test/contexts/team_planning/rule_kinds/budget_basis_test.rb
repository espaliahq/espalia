# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::BudgetBasisTest < ActiveSupport::TestCase
  def check(value) = TeamPlanning::RuleKinds.check("budget_basis", value)

  def refusal(value) = assert_raises(TeamPlanning::Error) { check(value) }.message

  should "default to a budget that includes on-costs" do
    assert TeamPlanning::RuleKinds::BudgetBasis.inclusive?(TeamPlanning::RuleKinds.defaults.fetch("budget_basis"))
  end

  should "keep either basis" do
    assert_equal({ "basis" => "base_only" }, check({ basis: "base_only" }))
    assert_not TeamPlanning::RuleKinds::BudgetBasis.inclusive?(check({ basis: "base_only" }))
  end

  should "refuse another basis, and any other key" do
    assert_equal "basis must be inclusive or base_only", refusal({ basis: "gross" })
    assert_equal "A budget_basis rule takes only basis, not currency", refusal({ basis: "inclusive", currency: "EUR" })
  end
end
