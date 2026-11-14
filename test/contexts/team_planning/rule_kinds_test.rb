# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKindsTest < ActiveSupport::TestCase
  def kind(name, shreddable: false)
    Class.new(TeamPlanning::RuleKind) do
      define_singleton_method(:rule_name) { name }
      define_singleton_method(:default) { { cap: 1 } }
      define_singleton_method(:shreddable?) { shreddable }
    end
  end

  should "hold every built-in kind once, each complete" do
    assert_equal TeamPlanning::RuleKinds::BUILT_IN.uniq, TeamPlanning::RuleKinds::BUILT_IN
    TeamPlanning::RuleKinds::BUILT_IN.map(&:constantize).each do |built_in|
      assert_kind_of String, built_in.description
      assert_equal built_in.default.deep_stringify_keys, TeamPlanning::RuleKinds.check(built_in.rule_name, built_in.default)
    end
  end

  should "hold a registered kind until it is unregistered, with its default under string keys" do
    test_kind = kind("test_cap")
    TeamPlanning::RuleKinds.register(test_kind)

    assert_equal test_kind, TeamPlanning::RuleKinds.fetch("test_cap")
    assert_equal({ "cap" => 1 }, TeamPlanning::RuleKinds.defaults["test_cap"])
  ensure
    TeamPlanning::RuleKinds.unregister(test_kind)
    assert_raises(TeamPlanning::Error) { TeamPlanning::RuleKinds.fetch("test_cap") }
  end

  should "refuse a kind with a shreddable value until shredding lands" do
    error = assert_raises(ArgumentError) { TeamPlanning::RuleKinds.register(kind("test_rate", shreddable: true)) }

    assert_match "issues/213", error.message
  end

  should "refuse a second kind with a name another kind holds, and keep the first" do
    first = kind("test_cap")
    TeamPlanning::RuleKinds.register(first)

    error = assert_raises(ArgumentError) { TeamPlanning::RuleKinds.register(kind("test_cap")) }
    assert_match "already holds", error.message
    assert_equal first, TeamPlanning::RuleKinds.fetch("test_cap")
  ensure
    TeamPlanning::RuleKinds.unregister(first)
  end

  should "refuse a kind whose name isn't snake_case, and a class that isn't a kind" do
    assert_raises(ArgumentError) { TeamPlanning::RuleKinds.register(kind("Test Cap")) }
    assert_raises(ArgumentError) { TeamPlanning::RuleKinds.register(String) }
  end
end
