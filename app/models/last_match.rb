# frozen_string_literal: true

# Walks an ordered list of entries, each a matcher plus what it applies,
# and finds the one with the last word for a subject (#368). A matcher
# matches on the fields it sets and ignores the ones it leaves nil. Every
# entry that matches applies, so the last one to match wins, and the order
# of the entries is the precedence.
#
# A subject's field can hold a set where the subject sits in several at
# once, matching when it includes the matcher's value: a seat carries its
# unit and every unit above it, so a unit's entry reaches the units beneath.
#
# Pay bands use it; cost-centre rules are meant to.
#
# @example
#   LastMatch.find(bands, { role_id: "r1", level_ordinal: 3 }, %i[role_id level_ordinal], &:matcher)
#   # => [band, 4]
module LastMatch
  # @param entries [Array] in order
  # @param subject [Hash{Symbol => Object}] the subject's attributes, each a value or a set of values
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
  # @param subject [Hash{Symbol => Object}] each field a value or a set of values
  # @param fields [Array<Symbol>]
  # @return [Boolean] whether the subject has every field the matcher sets
  def self.matches?(matcher, subject, fields) = fields.all? { matcher[it].nil? || has?(subject[it], matcher[it]) }

  def self.has?(held, value) = held.is_a?(Set) || held.is_a?(Array) ? held.include?(value) : held == value
  private_class_method :has?

  # The entries that can never have the last word: for each, a later entry
  # matches every subject it does.
  #
  # @param matchers [Array<Hash{Symbol => Object}>] in order
  # @param fields [Array<Symbol>]
  # @param reaches [Array<Hash{Symbol => Object}>] for each entry, what every subject it matches has,
  #   where a field implies another (a role its family, a unit the units above it); the matchers by default
  # @return [Array<Integer>] the indexes of those entries
  def self.shadowed(matchers, fields, reaches: matchers)
    matchers.each_index.select do |index|
      matchers.drop(index + 1).any? { matches?(it, reaches[index], fields) }
    end
  end
end
