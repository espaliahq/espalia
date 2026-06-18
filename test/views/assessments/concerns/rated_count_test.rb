# frozen_string_literal: true

require "test_helper"

class Views::Assessments::Concerns::RatedCountTest < ActiveSupport::TestCase
  # Minimal includer — the concern is a mixin into Phlex views, but its logic
  # is pure (operates on the `category_data` hash shape MatrixDataBuilder
  # returns), so we exercise it through a throwaway class.
  class Includer
    include Views::Assessments::Concerns::RatedCount
  end

  # Builds a category_data hash with the cell shape the builder produces.
  # `cells_per_cap` is an array (one per capability) of
  # `{ ordinal => frequency_or_nil }` maps keyed by level ordinal.
  def category_data(person_level:, cells_per_cap:)
    {
      person_level: person_level,
      capabilities: cells_per_cap.map do |cells|
        { cells: cells.transform_values { |freq| { current_frequency: freq } } }
      end
    }
  end

  setup { @subject = Includer.new }

  context "#category_rated_count" do
    should "count only the cell at the person's current level, one per capability" do
      data = category_data(
        person_level: 3,
        cells_per_cap: [
          { 2 => "consistent", 3 => "some",  4 => nil },        # rated at L3
          { 2 => "consistent", 3 => nil,     4 => "consistent" }, # unrated at L3
          { 1 => "some",       3 => "none",  5 => nil }          # rated at L3
        ]
      )

      assert_equal({ rated: 2, total: 3 }, @subject.category_rated_count(data, :self))
    end

    should "exclude lower- and higher-level ratings from the total" do
      # Every level except the current one is rated; current-level cells are blank.
      data = category_data(
        person_level: 3,
        cells_per_cap: [
          { 2 => "consistent", 3 => nil, 4 => "consistent" },
          { 2 => "consistent", 3 => nil, 4 => "consistent" }
        ]
      )

      assert_equal({ rated: 0, total: 2 }, @subject.category_rated_count(data, :self))
    end

    should "skip capabilities with no cell at the current level" do
      data = category_data(
        person_level: 3,
        cells_per_cap: [
          { 3 => "some" },
          { 4 => "consistent" }  # no L3 cell — not counted
        ]
      )

      assert_equal({ rated: 1, total: 1 }, @subject.category_rated_count(data, :self))
    end

    should "use the manager frequency key in manager context" do
      data = {
        person_level: 3,
        capabilities: [
          { cells: { 3 => { current_frequency: nil, manager_frequency: "consistent" } } }
        ]
      }

      assert_equal({ rated: 1, total: 1 }, @subject.category_rated_count(data, :manager))
    end
  end
end
