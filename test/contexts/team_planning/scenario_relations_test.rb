# frozen_string_literal: true

require "test_helper"

# A scenario's relation decides its period, its column on the timeline and
# where the next step goes, and each reader branches on it. These checks fail
# when a relation is added or a reader is written without handling them all.
class TeamPlanning::ScenarioRelationsTest < ActiveSupport::TestCase
  RELATIONS = TeamPlanning::PlanAggregate::RELATIONS

  # Readers that ask after one relation alone, each reviewed against every
  # relation: a new one needs this list read again before it joins RELATIONS.
  SINGLE_COMPARISONS = {
    "app/contexts/team_planning/plan_aggregate.rb" => {
      "then" => 6, # a fork's next step or alternative, a held end, a parent's one next step, the first steps a rebase moves,
      # and the steps a change moves later into: the next step, and what stands in its place
      "on" => 4 # either half of a split pair, what rests on a scenario, and a parent's next step taken by the rest of a split
    }
  }.freeze

  CASE_ON_RELATION = /^(\s*)case\s+\S*relation\]?\s*$/
  COMPARISON = /relation\]?\s*(?:==|!=)\s*"(\w+)"/

  def sources = Rails.root.glob("app/**/*.rb").map { [ it.relative_path_from(Rails.root).to_s, it.readlines ] }

  # Each `case` on a relation, the literals its `in` arms name (nil for the baseline's), and whether it has an else.
  def cases
    sources.flat_map do |path, lines|
      lines.each_index.filter_map do |index|
        indent = lines[index][CASE_ON_RELATION, 1] or next
        body = lines.drop(index + 1).take_while { !it.match?(/^#{indent}end\b/) }
        arms = body.grep(/^#{indent}in /)
        [ "#{path}:#{index + 1}", arms.flat_map { it.scan(/"(\w+)"|\b(nil)\b/).flatten.compact }.map { it == "nil" ? nil : it },
          body.grep(/^#{indent}else\b/).any? ]
      end
    end
  end

  should "know every relation the plan has, so a new one sends its author through the readers" do
    assert_equal %w[then instead on], RELATIONS,
                 "A new relation: handle it in every case on relation, read SINGLE_COMPARISONS again, then add it here"
  end

  should "handle every relation in each case on one, with no else to swallow a new one" do
    assert_operator cases.size, :>=, 6
    cases.each do |where, literals, fallback|
      assert_not fallback, "#{where} has an else, which would take a new relation without a word"
      assert_equal RELATIONS.sort, literals.compact.uniq.sort, "#{where} handles #{literals.inspect}"
    end
  end

  should "ask after a single relation only where each reader has been checked against them all" do
    found = sources.filter_map do |path, lines|
      counts = lines.flat_map { it.scan(COMPARISON).flatten }.tally
      [ path, counts ] if counts.any?
    end.to_h

    assert_equal SINGLE_COMPARISONS, found, "Branch on a relation with a case that names them all, or add the reader here once checked"
  end

  should "refuse a relation no reader knows, rather than read it as one it isn't" do
    assert_raises(NoMatchingPatternError) { Views::Plans::ScenarioDialogs.onward?({ relation: "beside" }) }
  end
end
