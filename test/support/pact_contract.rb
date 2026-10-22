# frozen_string_literal: true

require "pact/ffi"
require "pact/ffi/http_consumer"
require "pact/ffi/mock_server"
require "pact/ffi/verifier"

# Pact for Minitest, straight on pact_ffi: the Rust core pact-js uses too. The
# pact gem's own DSL is RSpec-only. Pact specification V3, no broker.
#
# Consumer side: {Consumer} records the interactions one test drives, serves
# them from the FFI mock server, fails the test on any mismatch and merges them
# into a pact file. Provider side: {.verify} replays a pact against a running
# app. The feedback exchange's use of both is in docs/guidelines/feedback-exchange.md.
module PactContract
  SPEC_V3 = PactFfi::FfiSpecificationVersion.fetch("SPECIFICATION_VERSION_V3")
  REQUEST = PactFfi::FfiInteractionPart.fetch("INTERACTION_PART_REQUEST")
  RESPONSE = PactFfi::FfiInteractionPart.fetch("INTERACTION_PART_RESPONSE")

  # The gem attaches the verifier's execute without releasing Ruby's lock, which
  # would starve the in-process app it is calling.
  module Blocking
    extend FFI::Library
    ffi_lib DetectOS.get_bin_path
    attach_function :verifier_execute, :pactffi_verifier_execute, [ :pointer ], :int32, blocking: true
  end

  module_function

  # @return [Hash] a value the peer may vary within its JSON type
  def like(value) = { "pact:matcher:type" => "type", "value" => value }

  # @return [Hash] a string the peer may vary within the pattern
  def term(regex, value) = { "pact:matcher:type" => "regex", "regex" => regex, "value" => value }

  # @return [Hash] a non-empty array whose items match the example's type
  def each_like(value, min: 1) = { "pact:matcher:type" => "type", "min" => min, "value" => Array(value) }

  # Replays every interaction of a pact against a running provider.
  #
  # @param pact_file [String, Pathname]
  # @param provider [String] the provider's name in the pact
  # @param base_url [String] where the provider listens
  # @param state_change_url [String] where the verifier POSTs `{ state, action }`
  # @return [Array(Boolean, String)] whether every interaction passed, and the report
  def verify(pact_file:, provider:, base_url:, state_change_url:)
    uri = URI(base_url)
    handle = PactFfi::Verifier.new_for_application("growthos-contract", "1")
    PactFfi::Verifier.set_provider_info(handle, provider, uri.scheme, uri.host, uri.port, uri.path.presence || "/")
    PactFfi::Verifier.set_provider_state(handle, state_change_url, 1, 1)
    PactFfi::Verifier.set_no_pacts_is_error(handle, 1)
    PactFfi::Verifier.set_coloured_output(handle, 0)
    PactFfi::Verifier.add_file_source(handle, pact_file.to_s)
    result = Blocking.verifier_execute(handle)
    [ result.zero?, PactFfi::Verifier.output(handle, 1).to_s ]
  ensure
    PactFfi::Verifier.shutdown(handle) if handle
  end

  # One test's interactions, served by the FFI mock server.
  class Consumer
    # @param consumer [String]
    # @param provider [String]
    # @param pact_dir [String, Pathname] where {#run} merges the pact file
    def initialize(consumer:, provider:, pact_dir:)
      @pact_dir = pact_dir.to_s
      @handle = PactFfi::HttpConsumer.new_pact(consumer, provider)
      PactFfi::HttpConsumer.with_specification(@handle, SPEC_V3)
    end

    # Declares an interaction; the block calls {Interaction#request} and {Interaction#response}.
    #
    # @param description [String] unique in the pact
    # @param given [String] the provider state
    # @return [void]
    def upon_receiving(description, given:)
      yield Interaction.new(PactFfi::HttpConsumer.new_interaction(@handle, description), description, given)
    end

    # Starts the mock server, yields its base URL, then fails unless every
    # interaction was received exactly as declared and nothing else was. Only a
    # clean run is merged into the pact file.
    #
    # @yieldparam base_url [String]
    # @return [Object] the block's value
    # @raise [Minitest::Assertion] on any mismatch
    def run
      port = PactFfi::MockServer.create_for_transport(@handle, "127.0.0.1", 0, "http", nil)
      raise "The Pact mock server did not start (#{port})" unless port.positive?

      begin
        begin
          value = yield "http://127.0.0.1:#{port}"
        rescue StandardError => e
          raised = e
        end
        # A mismatch is answered with a 500, so the code under test usually
        # fails too; the mismatch is the cause worth reporting.
        unless PactFfi::MockServer.matched(port)
          mismatches = JSON.pretty_generate(JSON.parse(PactFfi::MockServer.mismatches(port)))
          raise Minitest::Assertion, "The peer's mock did not get the pact's requests:\n#{mismatches}" \
                                     "#{"\nThe code under test then raised #{raised.class}: #{raised.message}" if raised}"
        end
        raise raised if raised

        written = PactFfi::MockServer.write_pact_file(port, @pact_dir, false)
        raise "Could not write the pact to #{@pact_dir} (#{written})" unless written.zero?

        value
      ensure
        PactFfi::MockServer.cleanup(port)
      end
    end
  end

  # The request and response of one interaction. Request values are literal:
  # the feedback exchange signs the path, query and body, so a matcher there
  # would record a signature the provider could never check.
  class Interaction
    def initialize(handle, description, given)
      @handle = handle
      PactFfi::HttpConsumer.upon_receiving(handle, description)
      PactFfi::HttpConsumer.given(handle, given)
    end

    # @param method [String]
    # @param path [String]
    # @param query [Hash{String=>String}]
    # @param headers [Hash{String=>String}]
    # @param body [String, nil] the exact JSON sent
    # @return [void]
    def request(method, path, query: {}, headers: {}, body: nil)
      PactFfi::HttpConsumer.with_request(@handle, method, path)
      query.each { |name, value| PactFfi::HttpConsumer.with_query_parameter_v2(@handle, name.to_s, 0, value.to_s) }
      headers.each { |name, value| PactFfi::HttpConsumer.with_header_v2(@handle, REQUEST, name, 0, value) }
      PactFfi::HttpConsumer.with_body(@handle, REQUEST, "application/json", body) if body
    end

    # @param status [Integer]
    # @param headers [Hash{String=>String, Hash}] a Hash value is a matcher
    # @param body [Hash, nil] may hold matchers from {PactContract}
    # @return [void]
    def response(status, headers: {}, body: nil)
      PactFfi::HttpConsumer.response_status(@handle, status)
      headers.each do |name, value|
        PactFfi::HttpConsumer.with_header_v2(@handle, RESPONSE, name, 0, value.is_a?(Hash) ? value.to_json : value)
      end
      PactFfi::HttpConsumer.with_body(@handle, RESPONSE, "application/json", body.to_json) if body
    end
  end
end
