# frozen_string_literal: true

# Swaps the names of a tenant's people for stable placeholders before text
# leaves for a model, and swaps them back in what comes back.
#
# Every person's full name, and their first name when it is theirs alone, becomes
# `Person N`. N is the person's rank among the tenant's people by id, which
# follows creation order, so a placeholder is the same on every request until
# someone is deleted and the same text caches. A first name two people share
# gets a placeholder of its own, so no placeholder ever stands for the wrong
# person.
#
# Matching is case-insensitive and on whole words, longest name first: "Anna"
# does not match inside "Annabel", and "Alex Chen" is taken before "Alex".
#
# The mapping lives in the instance and nowhere else: it is not stored, logged
# or sent. One instance serves one request, since {#restore} only undoes the
# placeholders {#pseudonymise} issued for it.
#
# This hides names. It does not anonymise: a role, a project or a quoted
# sentence can still identify a person to someone who knows the team.
#
# @example
#   pseudonymiser = Ai::NamePseudonymiser.for(tenant)
#   safe = pseudonymiser.pseudonymise("Alex Chen shipped it; Alex kept us informed.")
#   # => "Person 2 shipped it; Person 2 kept us informed."
#   pseudonymiser.restore("Person 2 owned the follow-up") # => "Alex Chen owned the follow-up"
class Ai::NamePseudonymiser
  WORD_EDGE_BEFORE = "(?<![\\p{L}\\p{N}_])"
  WORD_EDGE_AFTER = "(?![\\p{L}\\p{N}_])"
  PLACEHOLDER = /#{WORD_EDGE_BEFORE}Person (\d+)#{WORD_EDGE_AFTER}/i

  # @param tenant [Tenant]
  # @return [Ai::NamePseudonymiser]
  def self.for(tenant)
    new(ActsAsTenant.with_tenant(tenant) { Person.order(:id).pluck(:id, :name) })
  end

  # @param people [Array<Array(String, String)>] [id, name] pairs
  def initialize(people)
    @placeholders = build_placeholders(people)
    @pattern = build_pattern
    @seen = Hash.new { |hash, label| hash[label] = [] }
  end

  # @param text [String, nil]
  # @return [String, nil] the text with every name replaced
  def pseudonymise(text)
    return text if text.blank? || @pattern.nil?

    text.gsub(@pattern) do |match|
      label = @placeholders[match.squish.downcase]
      next match if label.nil?

      @seen[label] << match.squish
      label
    end
  end

  # Puts the names back wherever a placeholder issued by {#pseudonymise}
  # appears. A placeholder the model made up, or one that was in the text to
  # begin with, is left alone.
  #
  # @param text [String, nil]
  # @return [String, nil]
  def restore(text)
    return text if text.blank? || @seen.empty?

    text.gsub(PLACEHOLDER) do |match|
      label = "Person #{Regexp.last_match(1)}"
      @seen.key?(label) ? @seen[label].max_by(&:length) : match
    end
  end

  private

  # name (downcased) => "Person N"
  def build_placeholders(people)
    owners = Hash.new { |hash, name| hash[name] = [] }
    ranked = people.each_with_index.map { |(id, name), index| [ id, name.to_s.squish, index + 1 ] }
    ranked.each do |id, name, _rank|
      next if name.blank?

      owners[name.downcase] << id
      first = name.split(" ").first
      owners[first.downcase] << id if first != name && first.length >= 2
    end

    rank_of = ranked.to_h { |id, _name, rank| [ id, rank ] }
    next_shared = ranked.size
    owners.sort_by(&:first).to_h do |name, ids|
      ids = ids.uniq
      [ name, "Person #{ids.one? ? rank_of.fetch(ids.first) : (next_shared += 1)}" ]
    end
  end

  def build_pattern
    return nil if @placeholders.empty?

    names = @placeholders.keys.sort_by { |name| [ -name.length, name ] }
    Regexp.new("#{WORD_EDGE_BEFORE}(?:#{names.map { |name| Regexp.escape(name).gsub("\\ ") { "\\s+" } }.join('|')})#{WORD_EDGE_AFTER}", Regexp::IGNORECASE)
  end
end
