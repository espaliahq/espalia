# frozen_string_literal: true

# Keeps the client from being pointed at the app's own network.
#
# The peer address is typed by a tenant admin and the client calls it from the
# server, so an address like https://10.0.0.5, or a name that resolves to
# 169.254.169.254, would turn "Test connection" into a probe of internal services.
#
# Two checks. Development skips them, since the peer there is an app on the
# developer's machine (`host.docker.internal` from the devcontainer); it logs
# once per host when that lets a private address through. No other
# environment has the allowance.
#
#
# 1. The host must be a canonical hostname or a canonical IP literal. A host such
#    as `127.1`, `2130706433`, `0x7f000001` or `0177.0.0.1` is loopback to the
#    system resolver but is not an IP literal to Ruby's parser, so judging it by
#    name alone, or through `Resolv`, lets it through.
# 2. Every address the host resolves to, by the same resolver Net::HTTP uses
#    (`Addrinfo`), must be public.
#
# {.check!} returns the address it accepted, and the client connects to exactly
# that address (keeping the hostname for TLS and the Host header), so a second DNS
# answer cannot send the request somewhere the check never saw.
module FeedbackExchange::HostGuard
  LOCAL_SUFFIXES = %w[.localhost .local .internal .lan].freeze
  # One to 63 letters, digits or hyphens, not starting or ending with a hyphen.
  HOSTNAME = /\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\z/i
  # A last label of digits or 0x-hex is how legacy IPv4 shorthand ends, so such a
  # host is parsed as an address by the system resolver, whatever it looks like.
  NUMERIC_TAIL = /\A(0x[0-9a-f]*|[0-9]+)\z/i
  CANONICAL_IPV4 = /\A(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}\z/
  # Ranges `IPAddr#private?`, `#loopback?` and `#link_local?` do not cover.
  REFUSED_RANGES = %w[
    0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 ::/128
  ].map { |range| IPAddr.new(range) }.freeze

  module_function

  # @param host [String, nil]
  # @return [Boolean] whether the host is a canonical hostname or IP literal, so
  #   that what we judge is what the resolver will connect to
  def canonical_host?(host)
    bracketed = host.to_s.start_with?("[")
    host = unbracket(host)
    return false if host.blank?
    return ip_literal?(host) if bracketed || host.include?(":")
    return host.match?(CANONICAL_IPV4) if host.split(".").last.to_s.match?(NUMERIC_TAIL)

    host.match?(HOSTNAME)
  end

  # @param host [String, nil]
  # @return [Boolean] whether the host names a local machine or a private address,
  #   judged from the name alone (no DNS)
  def private_host?(host)
    host = unbracket(host).downcase
    return true if host == "localhost" || LOCAL_SUFFIXES.any? { |suffix| host.end_with?(suffix) }

    private_address?(host)
  end

  # @param address [String] an IP literal
  # @return [Boolean] whether it is loopback, private, link-local, reserved, or an
  #   IPv4 address wrapped in IPv6 (`::ffff:127.0.0.1`, `::127.0.0.1`)
  def private_address?(address)
    ip = IPAddr.new(address.to_s)
    ip = ip.native if ip.ipv6? && (ip.ipv4_mapped? || ip.ipv4_compat?)
    ip.loopback? || ip.private? || ip.link_local? || REFUSED_RANGES.any? { |range| range.include?(ip) }
  rescue IPAddr::Error
    false
  end

  # @param url [String] the peer's base URL
  # @return [String, nil] a public address for the host, which the connection must
  #   use; nil only in development
  # @raise [FeedbackExchange::Errors::AddressRefused] when the host is not canonical,
  #   does not resolve (a name that fails once and answers later could be anything),
  #   or is, or resolves to, a private address
  def check!(url)
    return allow_in_development(url) if Rails.env.development?

    host = unbracket(URI.parse(url).host)
    refuse!("The peer's address is not a plain hostname or IP address") unless canonical_host?(host)
    refuse!("The peer's address points at a private network address") if private_host?(host)
    addresses = resolved_addresses(host)
    refuse!("The peer's address does not resolve") if addresses.empty?
    refuse!("The peer's address resolves to a private network address") if addresses.any? { |a| private_address?(a) }
    addresses.first
  end

  # @param url [String]
  # @return [Boolean] whether development is letting a private or loopback peer
  #   through that any other environment would refuse
  def development_allowance?(url)
    return false unless Rails.env.development?

    host = unbracket(URI.parse(url.to_s).host)
    private_host?(host) || resolved_addresses(host).any? { |address| private_address?(address) }
  rescue URI::InvalidURIError
    false
  end

  # Lets a private peer through in development, logging each host the first time.
  #
  # @param url [String]
  # @return [nil] there is no address to pin the connection to
  def allow_in_development(url)
    return unless development_allowance?(url)

    host = URI.parse(url).host
    @allowed_in_development ||= Set.new
    return unless @allowed_in_development.add?(host)

    Rails.logger.info("[FeedbackExchange] Development only: allowing the private peer address #{host}")
    nil
  end

  def resolved_addresses(host)
    Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq
  rescue SocketError
    []
  end

  def ip_literal?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::Error
    false
  end

  def unbracket(host) = host.to_s.delete_prefix("[").delete_suffix("]")

  def refuse!(message)
    raise FeedbackExchange::Errors::AddressRefused, message
  end
end
