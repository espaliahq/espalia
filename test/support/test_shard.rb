# frozen_string_literal: true

require "zlib"

# Runs one slice of the suite when TEST_SHARD is "index/total" (1-based), so CI
# can spread the system tests across jobs. It splits by test, not by file: two
# files hold over a quarter of the system suite.
module TestShard
  FORMAT = %r{\A(\d+)/(\d+)\z}

  # Deals a class's tests round-robin, starting at a per-class offset, so every
  # shard gets an even share of each class and no shard collects all the remainders.
  #
  # @param methods [Array<String>] the class's runnable methods, in run order
  # @param class_name [String]
  # @param index [Integer] this shard, from 1
  # @param total [Integer] how many shards there are
  # @return [Array<String>] this shard's methods, still in run order
  def self.select(methods, class_name:, index:, total:)
    offset = Zlib.crc32(class_name.to_s)
    kept = methods.sort.select.with_index { |_, position| (position + offset) % total == index - 1 }
    methods & kept
  end

  # A shard outside 1..total would quietly run nothing and pass, so it raises.
  #
  # @param value [String] e.g. "3/12"
  # @return [Hash{Symbol => Integer}] index: and total:
  def self.parse(value)
    match = FORMAT.match(value.to_s)
    index, total = match&.captures&.map(&:to_i)
    raise ArgumentError, "TEST_SHARD must be index/total with 1 <= index <= total, got #{value.inspect}" unless match && index.between?(1, total)

    { index: index, total: total }
  end

  module Filter
    def runnable_methods
      TestShard.select(super, class_name: name, **TestShard.parse(ENV["TEST_SHARD"]))
    end
  end
end

Minitest::Test.singleton_class.prepend(TestShard::Filter) if ENV["TEST_SHARD"]
