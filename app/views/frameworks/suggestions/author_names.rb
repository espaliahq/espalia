# frozen_string_literal: true

# Resolves suggestion author_id / reviewer_id UUIDs to Person names.
#
# Both columns are foreign keys to people(id) (see
# CreateFrameworkSuggestedEdits), and ApplicationController#auto_link_person
# guarantees every TenantUser has a linked Person — so any id stored here is
# a valid Person.id in the current tenant. The resolver is a thin bulk lookup
# (one query) with a defensive truncated-UUID fallback for the rare case
# where a Person has been hard-deleted out from under a suggestion.
#
# @example
#   names = Views::Frameworks::Suggestions::AuthorNames.for(suggestions.map(&:author_id))
#   names.resolve(suggestion.author_id) # => "Alice Smith"
#
class Views::Frameworks::Suggestions::AuthorNames
  # @param ids [Array<String, nil>] raw UUIDs — nils and blanks are ignored
  # @return [AuthorNames]
  def self.for(ids)
    new(ids)
  end

  def initialize(ids)
    @ids = Array(ids).compact.reject(&:blank?).uniq
    @lookup = @ids.empty? ? {} : Person.where(id: @ids).pluck(:id, :name).to_h
  end

  # @param id [String, nil]
  # @return [String]
  def resolve(id)
    return "" if id.blank?
    @lookup[id] || fallback(id)
  end

  private

  def fallback(id)
    "#{id[0, 8]}\u2026"
  end
end
