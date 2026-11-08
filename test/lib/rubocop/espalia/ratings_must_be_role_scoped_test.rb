# frozen_string_literal: true

require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/espalia/ratings_must_be_role_scoped")

class RuboCop::Cop::Espalia::RatingsMustBeRoleScopedTest < ActiveSupport::TestCase
  # @param source [String] Ruby source to inspect
  # @return [Array<String>] offense messages, in source order
  def offenses_for(source)
    cop = RuboCop::Cop::Espalia::RatingsMustBeRoleScoped.new
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f)
    commissioner = RuboCop::Cop::Commissioner.new([ cop ])
    report = commissioner.investigate(processed)
    report.offenses.reject(&:disabled?).sort_by(&:line).map(&:message)
  end

  context "unscoped reads" do
    should "flag a where chain that never names a role" do
      messages = offenses_for(<<~RUBY)
        AssessmentLevelRating.where(cycle_id: cycle_id, person_id: ids).count
      RUBY
      assert_equal 1, messages.size
      assert_match(/within\(scope\)/, messages.first)
      assert_match(/across_all_roles/, messages.first)
    end

    should "flag a chain of named scopes" do
      messages = offenses_for(<<~RUBY)
        AssessmentLevelRating.for_cycle(cycle_id).for_person(person_id).self_rated.exists?
      RUBY
      assert_equal 1, messages.size
    end

    should "flag the top-level constant form" do
      assert_equal 1, offenses_for("::AssessmentLevelRating.for_cycle(cycle_id).pluck(:person_id)\n").size
    end

    should "flag a find_by that does not name one cell" do
      assert_equal 1, offenses_for("AssessmentLevelRating.find_by(person_id: person_id, cycle_id: cycle_id)\n").size
    end

    should "flag a relation assigned and scoped later — the root chain must say it" do
      messages = offenses_for(<<~RUBY)
        rows = AssessmentLevelRating.for_cycle(cycle_id)
        rows.within(scope)
      RUBY
      assert_equal 1, messages.size
    end
  end

  context "scoped or exempt reads" do
    should "accept .within anywhere in the chain" do
      assert_empty offenses_for(<<~RUBY)
        AssessmentLevelRating.for_cycle(cycle_id).within(scopes).where(level_ordinal: 3).pluck(:person_id)
      RUBY
    end

    should "accept .within after a block in the chain" do
      assert_empty offenses_for("AssessmentLevelRating.for_cycle(id).tap { |r| r }.within(scope).count\n")
    end

    should "accept an announced .across_all_roles" do
      assert_empty offenses_for("AssessmentLevelRating.across_all_roles.where(person_id: ids)\n")
    end

    should "accept a single-cell lookup on the natural key" do
      assert_empty offenses_for(<<~RUBY)
        AssessmentLevelRating.find_by(cycle_id:, person_id:, framework_id:,
                                      capability_stable_id: stable_id, level_ordinal: ordinal)
      RUBY
    end

    should "accept building a record and reading constants" do
      assert_empty offenses_for(<<~RUBY)
        AssessmentLevelRating.new(person_id: id)
        AssessmentLevelRating::FREQUENCIES.each { |f| f }
      RUBY
    end

    should "accept the class passed as an argument" do
      assert_empty offenses_for("grouped_counts(AssessmentLevelRating, people, framework_id, ids)\n")
    end

    should "respect an inline disable comment" do
      assert_empty offenses_for(<<~RUBY)
        AssessmentLevelRating.where(person_id: id).count # rubocop:disable Espalia/RatingsMustBeRoleScoped
      RUBY
    end
  end
end
