# frozen_string_literal: true

# Low-level HTTP client for the HiBob API.
#
# Handles authentication, pagination, rate limiting, and retries.
# Each instance is scoped to a single tenant's credentials — no global state.
#
# @example
#   client = Hris::Hibob::Client.new(
#     service_user_id: "...",
#     api_token: "..."
#   )
#   employees = client.search_people(fields: [...], show_inactive: true)
#
class Hris::Hibob::Client
  BASE_URL = "https://api.hibob.com/v1/"
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 2

  # A level field stored before #67 is a bare custom-column id. Since then it
  # is the catalogue id, the field's full path.
  CUSTOM_COLUMN_PREFIX = "work.customColumns."
  BARE_CUSTOM_COLUMN = /\Acolumn_[^.\/]+\z/

  BASE_FIELDS = %w[
    root.id root.email root.firstName root.surname root.displayName
    root.isActive
    work.title work.department work.reportsTo work.site work.startDate
    work.isManager
    payroll.employment.fte payroll.employment.type internal.terminationDate
  ].freeze

  # @param service_user_id [String] HiBob service user ID
  # @param api_token [String] HiBob API token
  # @param level_field_id [String, nil] the HiBob field holding the level
  #   ordinal, as its path (`work.customColumns.column_0000000000000`) or as a
  #   bare custom-column id. When set, every search requests it.
  def initialize(service_user_id:, api_token:, level_field_id: nil)
    @service_user_id = service_user_id
    @api_token = api_token
    @level_field_id = level_field_id
  end

  # Computes the default field set, including the level custom column when configured.
  #
  # @return [Array<String>]
  def default_fields
    fields = BASE_FIELDS.dup
    level_field = self.class.field_path(@level_field_id)
    fields << level_field if level_field
    fields
  end

  # The field's path as the people API takes it. Only a bare custom-column id
  # (`column_…`) gains a prefix; anything else is already the field's id.
  #
  # @param field_id [String, nil]
  # @return [String, nil]
  def self.field_path(field_id)
    return if field_id.blank?

    field_id.match?(BARE_CUSTOM_COLUMN) ? "#{CUSTOM_COLUMN_PREFIX}#{field_id}" : field_id
  end

  # Fetches all employees via POST /people/search with cursor-based pagination.
  #
  # @param fields [Array<String>] fields to include in the response
  # @param show_inactive [Boolean] whether to include inactive employees
  # @return [Array<Hash>] all employees across all pages
  def search_people(fields: default_fields, show_inactive: true)
    all_employees = []
    cursor = nil

    loop do
      body = {
        fields: fields,
        showInactive: show_inactive,
        humanReadable: "APPEND"
      }
      body[:cursor] = cursor if cursor

      response = request_with_retry(:post, "people/search", body: body)
      employees = response["employees"]
      # A page without its list would otherwise end the fetch early, and the
      # people on the pages never read would read as having left.
      raise Hris::Hibob::Errors::UnexpectedResponseError, "HiBob people search page has no employee list" unless employees.is_a?(Array)

      all_employees.concat(employees)

      cursor = response["cursor"]
      break if cursor.blank? || employees.empty?
    end

    all_employees
  end

  # Fetches field metadata.
  #
  # @return [Array<Hash>] field definitions
  def get_fields
    request_with_retry(:get, "company/people/fields")
  end

  # Fetches company named lists (departments, sites, etc.).
  #
  # @return [Array<Hash>] named lists
  def get_named_lists
    request_with_retry(:get, "company/named-lists")
  end

  private

  attr_reader :service_user_id, :api_token

  # @return [Faraday::Connection]
  def connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :json
      f.response :json
      f.response :raise_error
      f.adapter Faraday.default_adapter
      f.headers["Authorization"] = "Basic #{Base64.strict_encode64("#{service_user_id}:#{api_token}")}"
      f.headers["Accept"] = "application/json"
    end
  end

  # Executes a request with retry logic and rate limit handling.
  #
  # @param method [Symbol] HTTP method (:get, :post, etc.)
  # @param path [String] API path relative to BASE_URL
  # @param body [Hash, nil] request body for POST/PUT
  # @return [Hash] parsed response body
  def request_with_retry(method, path, body: nil)
    retries = 0
    begin
      response = connection.public_send(method, path) do |req|
        req.body = body if body
      end
      response.body
    rescue Faraday::UnauthorizedError
      raise Hris::Hibob::Errors::AuthenticationError, "Invalid HiBob credentials"
    rescue Faraday::TooManyRequestsError => e
      retry_after = e.response&.dig(:headers, "retry-after")&.to_i || RETRY_BASE_DELAY
      raise Hris::Hibob::Errors::RateLimitError.new(retry_after: retry_after)
    rescue Faraday::ClientError, Faraday::ServerError => e
      retries += 1
      if retries <= MAX_RETRIES
        sleep(RETRY_BASE_DELAY**retries)
        retry
      end
      raise Hris::Hibob::Errors::ApiError.new(
        status: e.response&.dig(:status),
        body: e.response&.dig(:body)
      )
    end
  end
end
