# frozen_string_literal: true

require "test_helper"

class OrgGraph::TaxonomyTest < ActiveSupport::TestCase
  setup do
    @division, @department, @team, @squad = Array.new(4) { SecureRandom.uuid_v7 }
  end

  context "a level written before kinds stated their rules" do
    should "let each Espalia level sit under every level above it, or at the top" do
      taxonomy = OrgGraph::Taxonomy.new(levels)

      assert_equal [ [], [ @division ], [ @division, @department ], [ @division, @department, @team ] ],
                   taxonomy.kinds.map(&:parent_ids)
      assert(taxonomy.kinds.all?(&:top?))
      assert taxonomy.allows?(@squad, beneath: @division)
      assert_not taxonomy.allows?(@team, beneath: @squad)
      assert_not taxonomy.allows?(@team, beneath: @team)
    end

    should "let a level an HRIS provides sit only under the HRIS level directly above it" do
      taxonomy = OrgGraph::Taxonomy.new(levels, providers: { @division => "hibob", @department => "hibob", @team => "hibob" })

      assert_equal [ [], [ @division ], [ @department ], [ @division, @department, @team ] ],
                   taxonomy.kinds.map(&:parent_ids)
      assert_equal %w[hibob hibob hibob espalia], taxonomy.kinds.map(&:provider)
    end

    should "give a level an HRIS provides no parent kind when Espalia holds the level above" do
      taxonomy = OrgGraph::Taxonomy.new(levels, providers: { @department => "hibob" })

      assert_empty taxonomy.kind(@department).parent_ids
    end
  end

  context "a level that states its rules" do
    should "take its parent kinds and its place at the top from the event" do
      taxonomy = OrgGraph::Taxonomy.new([
        { "level_id" => @team, "name" => "Team", "parent_level_ids" => [ @squad ], "top" => false },
        { "level_id" => @squad, "name" => "Squad", "parent_level_ids" => [ @team, @squad ], "top" => true }
      ])

      assert taxonomy.allows?(@team, beneath: @squad)
      assert taxonomy.allows?(@squad, beneath: @squad)
      assert_not taxonomy.may_be_top?(@team)
      assert taxonomy.may_be_top?(@squad)
    end
  end

  should "allow nothing for a kind it doesn't hold" do
    taxonomy = OrgGraph::Taxonomy.new(levels)

    assert_nil taxonomy.kind(SecureRandom.uuid_v7)
    assert_not taxonomy.allows?(SecureRandom.uuid_v7, beneath: @division)
    assert_not taxonomy.may_be_top?(SecureRandom.uuid_v7)
  end

  private

  def levels
    [ [ @division, "Division" ], [ @department, "Department" ], [ @team, "Team" ], [ @squad, "Squad" ] ]
      .map { |level_id, name| { level_id:, name: } }
  end
end
