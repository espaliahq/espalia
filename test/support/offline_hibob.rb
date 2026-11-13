# frozen_string_literal: true

# No test reaches the live HiBob API. A test drives the client through an
# injected Faraday connection (client tests) or a stubbed client (adapter
# tests); anything else, such as the HRIS page's level field frame loading in a
# system test, gets the error an unreachable HRIS gives, which the page shows.
module OfflineHibob
  private def connection
    @connection || raise(Hris::Hibob::Errors::ApiError.new(status: nil, body: "the live HiBob API is off in tests"))
  end
end

Hris::Hibob::Client.prepend(OfflineHibob)
