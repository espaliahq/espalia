# frozen_string_literal: true

require "test_helper"

# A shard that drops or repeats a test fails nothing: CI just stops running it.
class TestShardTest < ActiveSupport::TestCase
  METHODS = Array.new(23) { |i| "test_case_#{i}" }.shuffle(random: Random.new(1)).freeze

  def shards(total, class_name: "SomeSystemTest")
    (1..total).map { |index| TestShard.select(METHODS, class_name: class_name, index: index, total: total) }
  end

  context ".select" do
    should "run every test in exactly one shard, for any shard count" do
      (1..30).each do |total|
        assert_equal METHODS.sort, shards(total).flatten.sort, "#{total} shards"
      end
    end

    should "give each shard an even share of a class" do
      sizes = shards(12).map(&:size)

      assert_operator sizes.max - sizes.min, :<=, 1
    end

    should "keep the class's run order" do
      shards(4).each { |shard| assert_equal METHODS & shard, shard }
    end

    should "leave a different shard short for each class, so no shard is always the light one" do
      short = %w[AlphaTest BetaTest GammaTest DeltaTest].map { |name| shards(12, class_name: name).index { |shard| shard.size == 1 } }

      assert_operator short.uniq.size, :>, 1
    end
  end

  context ".parse" do
    should "read index/total" do
      assert_equal({ index: 3, total: 12 }, TestShard.parse("3/12"))
    end

    should "reject a shard that would run nothing" do
      [ "0/12", "13/12", "0/0", "3", "a/b", "", nil ].each do |value|
        assert_raises(ArgumentError, value.inspect) { TestShard.parse(value) }
      end
    end
  end
end
