# frozen_string_literal: true

# Walks an ordered list of entries, each a matcher plus what it applies,
# and finds the one with the last word for a subject (#368). A matcher
# matches on the fields it sets and ignores the ones it leaves nil. Every
# entry that matches applies, so the last one to match wins, and the order
# of the entries is the precedence.
#
# Pay bands use it; cost-centre rules are meant to.
#
# @example
#   LastMatch.find(bands, { role_id: "r1", level_ordinal: 3 }, %i[role_id level_ordinal], &:matcher)
#   # => [band, 4]
module LastMatch
  # @param entries [Array] in order
  # @param subject [Hash{Symbol => Object}] the subject's attributes
  # @param fields [Array<Symbol>] the matcher fields
  # @yieldparam entry [Object]
  # @yieldreturn [Hash{Symbol => Object}] the entry's matcher; the entry itself without a block
  # @return [Array(Object, Integer), nil] the last entry that matches and its index
  def self.find(entries, subject, fields, &matcher)
    matcher ||= :itself.to_proc
    (entries.size - 1).downto(0) do |index|
      return [ entries[index], index ] if matches?(matcher.call(entries[index]), subject, fields)
    end
    nil
  end

  # @param matcher [Hash{Symbol => Object}]
  # @param subject [Hash{Symbol => Object}]
  # @param fields [Array<Symbol>]
  # @return [Boolean] whether every field the matcher sets equals the subject's
  def self.matches?(matcher, subject, fields) = fields.all? { matcher[it].nil? || matcher[it] == subject[it] }

  # The entries that can never have the last word: for each, a later entry
  # matches every subject it does.
  #
  # @param matchers [Array<Hash{Symbol => Object}>] in order
  # @param fields [Array<Symbol>]
  # @param reaches [Array<Hash{Symbol => Object}>] for each entry, what every subject it matches has,
  #   where a field implies another (a role its family); the matchers themselves by default
  # @return [Array<Integer>] the indexes of those entries
  def self.shadowed(matchers, fields, reaches: matchers)
    matchers.each_index.select do |index|
      matchers.drop(index + 1).any? { matches?(it, reaches[index], fields) }
    end
  end
end
