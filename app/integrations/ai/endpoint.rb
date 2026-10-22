# frozen_string_literal: true

# Vets the address an AI adapter is about to call, with the same guard the
# feedback exchange uses ({FeedbackExchange::HostGuard}), and says so in the AI
# error set. The address is typed by a tenant admin and called from the server,
# so a private-network host, a numeric shorthand such as `127.1`, or a name that
# resolves inward would turn "Test connection" into a probe of internal services.
module Ai::Endpoint
  module_function

  # @param url [String] the endpoint's base URL, or one leg of a redirect
  # @return [String, nil] a public address for the host, which the connection
  #   must use; nil only in development
  # @raise [Ai::Errors::ConfigurationError] when the guard refuses the address
  def vet!(url)
    FeedbackExchange::HostGuard.check!(url)
  rescue FeedbackExchange::Errors::AddressRefused => e
    raise Ai::Errors::ConfigurationError, e.message.sub("The peer's address", "The model endpoint's address")
  end
end
