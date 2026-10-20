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
# Addresses are read the way the connection will read them, by the system
# resolver: `127.1`, `2130706433`, `0x7f000001` and `0177.0.0.1` all mean
# 127.0.0.1 to it, and none parses as an IP to Ruby's own IPAddr or resolves
# through Resolv.
#
# This closes the straightforward case. It does not stop DNS rebinding between
# this check and the connection; an egress policy at the network layer does.
module Ai::HostGuard
  LOCAL_SUFFIXES = %w[.localhost .local .internal .lan].freeze
  # IPv4 written as one to four dotted numbers, in decimal, octal or hex.
  NUMERIC_HOST = /\A(?:0x\h+|\d+)(?:\.(?:0x\h+|\d+)){0,3}\z/i
  # Ranges IPAddr#private? does not cover: "this network" and carrier-grade NAT.
  EXTRA_BLOCKED = [ IPAddr.new("0.0.0.0/8"), IPAddr.new("100.64.0.0/10") ].freeze

  module_function

  # @param host [String, nil]
  # @return [Boolean] whether the host names a local machine or a private
  #   address, judged from the name alone (no DNS)
  def private_host?(host)
    host = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
    return true if host == "localhost" || LOCAL_SUFFIXES.any? { |suffix| host.end_with?(suffix) }

    private_address?(host) || numeric_addresses(host).any? { |address| private_address?(address) }
  end

  # @param address [String] an IP literal
  # @return [Boolean]
  def private_address?(address)
    ip = IPAddr.new(address)
    ip = ip.native if ip.ipv4_mapped?
    ip.loopback? || ip.private? || ip.link_local? || ip == IPAddr.new("::") || EXTRA_BLOCKED.any? { |range| range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end

  # @param url [String] the endpoint's base URL
  # @raise [Ai::Errors::ConfigurationError] when the host is, or resolves to, a private address
  def check!(url)
    return if Rails.env.development?

    host = URI.parse(url).host.to_s.delete_prefix("[").delete_suffix("]")
    return unless private_host?(host) || resolve(host).any? { |address| private_address?(address) }

    raise Ai::Errors::ConfigurationError, "The model endpoint's address points at a private network address, which is not allowed"
  end

  # The numeric forms the system resolver accepts for an IPv4 host, as the
  # dotted quads it turns them into.
  def numeric_addresses(host)
    return [] unless host.match?(NUMERIC_HOST)

    Addrinfo.getaddrinfo(host, nil, :INET, :STREAM, nil, Socket::AI_NUMERICHOST).map(&:ip_address)
  rescue SocketError
    []
  end

  # What the connection would find: the system resolver's answer, which
  # includes the numeric shorthands Resolv does not.
  def resolve(host)
    Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address)
  rescue SocketError
    []
  end
end
