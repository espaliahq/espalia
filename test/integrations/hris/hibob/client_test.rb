# frozen_string_literal: true

require "test_helper"

class Hris::Hibob::ClientTest < ActiveSupport::TestCase
  setup do
    @stubs = Faraday::Adapter::Test::Stubs.new
    @client = Hris::Hibob::Client.new(
      service_user_id: "test-user",
      api_token: "test-token"
    )

    # Replace the client's connection with a stubbed one
    stubbed_connection = Faraday.new(url: Hris::Hibob::Client::BASE_URL) do |f|
      f.request :json
      f.response :json
      f.response :raise_error
      f.adapter :test, @stubs
      f.headers["Authorization"] = "Basic #{Base64.strict_encode64("test-user:test-token")}"
      f.headers["Accept"] = "application/json"
    end
    @client.instance_variable_set(:@connection, stubbed_connection)
  end

  context "#search_people" do
    should "fetch all employees from a single page" do
      fixture = JSON.parse(
        File.read(Rails.root.join("test/fixtures/files/hibob/people_search_response.json"))
      )

      @stubs.post("/v1/people/search") { [ 200, { "Content-Type" => "application/json" }, fixture ] }

      employees = @client.search_people
      assert_equal 3, employees.size
      assert_equal "bob-001", employees[0]["id"]
      @stubs.verify_stubbed_calls
    end

    should "handle cursor-based pagination across multiple pages" do
      page1 = {
        "employees" => [ { "id" => "bob-001", "email" => "a@b.com" } ],
        "cursor" => "next-page-token"
      }
      page2 = {
        "employees" => [ { "id" => "bob-002", "email" => "c@d.com" } ]
      }

      call_count = 0
      @stubs.post("/v1/people/search") do
        call_count += 1
        if call_count == 1
          [ 200, { "Content-Type" => "application/json" }, page1 ]
        else
          [ 200, { "Content-Type" => "application/json" }, page2 ]
        end
      end

      employees = @client.search_people
      assert_equal 2, employees.size
      assert_equal "bob-001", employees[0]["id"]
      assert_equal "bob-002", employees[1]["id"]
    end

    should "raise AuthenticationError on 401" do
      @stubs.post("/v1/people/search") { raise Faraday::UnauthorizedError }

      assert_raises(Hris::Hibob::Errors::AuthenticationError) do
        @client.search_people
      end
    end

    should "raise RateLimitError on 429" do
      @stubs.post("/v1/people/search") do
        raise Faraday::TooManyRequestsError.new(
          nil,
          { status: 429, headers: { "retry-after" => "30" }, body: "" }
        )
      end

      error = assert_raises(Hris::Hibob::Errors::RateLimitError) do
        @client.search_people
      end
      assert_equal 30, error.retry_after
    end
  end

  context "#get_fields" do
    should "fetch field metadata" do
      expected = [ { "id" => "work.title", "name" => "Title" } ]
      @stubs.get("/v1/company/people/fields") { [ 200, { "Content-Type" => "application/json" }, expected ] }

      result = @client.get_fields
      assert_equal expected, result
      @stubs.verify_stubbed_calls
    end
  end

  context "#get_named_lists" do
    should "fetch named lists" do
      expected = [ { "name" => "Department", "values" => [] } ]
      @stubs.get("/v1/company/named-lists") { [ 200, { "Content-Type" => "application/json" }, expected ] }

      result = @client.get_named_lists
      assert_equal expected, result
      @stubs.verify_stubbed_calls
    end
  end
end
