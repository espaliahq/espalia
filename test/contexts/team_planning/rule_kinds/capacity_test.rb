# frozen_string_literal: true

require "test_helper"

class TeamPlanning::RuleKinds::CapacityTest < ActiveSupport::TestCase
  Kind = TeamPlanning::RuleKinds::Capacity

  def per_fte = { "model" => "per_fte", "params" => {} }

  should "be built in, choosing nothing until a tenant or plan does" do
    assert_equal Kind, TeamPlanning::RuleKinds.fetch("capacity_model")
    assert_equal({ "families" => {}, "roles" => {} }, TeamPlanning::RuleKinds.defaults["capacity_model"])
  end

  should "store each choice with its ids downcased and its params as the model checked them" do
    value = TeamPlanning::RuleKinds.check("capacity_model", { families: { " ENG " => { model: "per_fte" } } })

    assert_equal({ "families" => { "eng" => per_fte }, "roles" => {} }, value)
  end

  should "let a role's choice beat its family's, and say which chose" do
    value = Kind.check({ "families" => { "eng" => per_fte }, "roles" => { "em" => per_fte } })

    assert_equal "role", Kind.choice_for(value, role_id: "em", family_id: "eng")["chosen_for"]
    assert_equal "family", Kind.choice_for(value, role_id: "se", family_id: "eng")["chosen_for"]
    assert_nil Kind.choice_for(value, role_id: "se", family_id: "design")
    assert_nil Kind.choice_for(value, role_id: "se", family_id: nil)
  end

  should "refuse an unknown model, another key, a choice without a model, and params the model refuses, never naming a param's value" do
    assert_raises(TeamPlanning::Error) { Kind.check({ "families" => { "eng" => { "model" => "story_points" } } }) }
    assert_raises(TeamPlanning::Error) { Kind.check({ "teams" => {} }) }
    assert_raises(TeamPlanning::Error) { Kind.check({ "roles" => { "em" => {} } }) }
    assert_raises(TeamPlanning::Error) { Kind.check({ "roles" => [] }) }
    assert_raises(TeamPlanning::Error) { Kind.check({ "roles" => { "em" => { "model" => "per_fte", "ramp" => 3 } } }) }

    error = assert_raises(TeamPlanning::Error) { Kind.check({ "roles" => { "em" => { "model" => "per_fte", "params" => { "rate" => "secret-91000" } } } }) }
    assert_no_match "secret", error.message
  end
end
