# frozen_string_literal: true

# Keeps the AI client from being pointed at the app's own network.
#
# The endpoint address is typed by a tenant admin and the adapters call it from
# the server, so an address like https://10.0.0.5, or one that resolves to
# 169.254.169.254, would turn "Test connection" into a probe of internal
# services. {.check!} refuses a host that is, or resolves to, a loopback,
# private or link-local address. Development is exempt, where a local model
# server is a normal endpoint.
#
# This closes the straightforward case. It does not stop DNS rebinding between
# this check and the connection; an egress policy at the network layer does.
module Ai::HostGuard
  LOCAL_SUFFIXES = %w[.localhost .local .internal .lan].freeze

  module_function

  # @param host [String, nil]
  # @return [Boolean] whether the host names a local machine or a private
  #   address, judged from the name alone (no DNS)
  def private_host?(host)
    host = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
    return true if host == "localhost" || LOCAL_SUFFIXES.any? { |suffix| host.end_with?(suffix) }

    private_address?(host)
  end

  # @param address [String] an IP literal
  # @return [Boolean]
  def private_address?(address)
    ip = IPAddr.new(address)
    ip = ip.native if ip.ipv4_mapped?
    ip.loopback? || ip.private? || ip.link_local? || ip == IPAddr.new("0.0.0.0") || ip == IPAddr.new("::")
  rescue IPAddr::InvalidAddressError
    false
  end

  # @param url [String] the endpoint's base URL
  # @raise [Ai::Errors::ApiError] when the host is, or resolves to, a private address
  def check!(url)
    return if Rails.env.development?

    host = URI.parse(url).host
    addresses = Resolv.getaddresses(host.to_s.delete_prefix("[").delete_suffix("]"))
    return unless private_host?(host) || addresses.any? { |address| private_address?(address) }

    raise Ai::Errors::ApiError.new(
      status: nil, message: "The model endpoint's address points at a private network address, which is not allowed"
    )
  end
end
