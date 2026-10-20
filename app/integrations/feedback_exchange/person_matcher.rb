# frozen_string_literal: true

# Finds the GrowthOS Person a protocol person (§3) names: by the id the
# tenant's HRIS holds when the peer sent one under that system's key, else by
# lower-cased email. A consumer never creates a person from a record; no match
# is nil, and the importer skips the record with a reason.
#
# @example
#   FeedbackExchange::PersonMatcher.new(tenant).match({ "email" => "priya@meandu.com", "external_ids" => { "hibob" => "3141" } })
class FeedbackExchange::PersonMatcher
  # @param tenant [Tenant]
  def initialize(tenant)
    @hris_source = tenant.hris_config&.provider.presence
    @cache = {}
  end

  # @param protocol_person [Hash, nil] { "email", "display_name", "active", "external_ids" }
  # @return [Person, nil]
  def match(protocol_person)
    return nil unless protocol_person.is_a?(Hash)

    email = protocol_person["email"].to_s.strip.downcase
    external_id = @hris_source && protocol_person.dig("external_ids", @hris_source)
    key = [ email, external_id ]
    return @cache[key] if @cache.key?(key)

    @cache[key] = Person.identified_by(email: email, external_id: external_id, hris_source: @hris_source)
  end
end
