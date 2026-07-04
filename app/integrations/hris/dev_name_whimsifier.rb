# frozen_string_literal: true

# Deterministically replaces real employee names with whimsical pseudonyms.
#
# Development-only PII guard: dev environments sync against real HRIS
# accounts to validate the integration, so real names must never land in a
# local database. The pseudonym is a pure function of the person's stable
# HRIS external id — every re-sync maps the same employee to the same
# whimsical name, and a manager's pseudonym in their reports' `reportsTo`
# payloads matches the manager's own record.
#
# Emails are deliberately left untouched: TenantUser auto-linking (sync
# Pass 4) and SSO sign-in both match on email, so scrambling them would
# break dev login flows. Keep dev seeds/credentials scoped accordingly.
#
# @example
#   Hris::DevNameWhimsifier.whimsical_name("bob-001")
#   # => "Peregrine Thistledown"  (stable for "bob-001" forever)
#
class Hris::DevNameWhimsifier
  FIRST_NAMES = %w[
    Amaranth Archibald Balthazar Barnaby Beatrix Bertram Bramble Casimir
    Clementine Clover Cornelius Dandelion Evangeline Ferdinand Fitzwilliam
    Hawthorn Humphrey Ignatius Isadora Juniper Lavender Leopold Marigold
    Marzipan Millicent Mortimer Obadiah Ottoline Peregrine Petronella
    Pippin Primrose Prudence Quillon Rosalind Sorrel Sylvester Tamsin
    Tansy Thaddeus Tuppence Ulysses Verbena Wilhelmina Winifred Wolfgang
    Xanthe Zinnia
  ].freeze

  SURNAMES = %w[
    Applethwaite Bindlestitch Bumblethorpe Cloudberry Crumpetworth
    Dabblewick Elderflower Fiddleford Fizzlewick Frostwhistle Gigglesworth
    Gooseberry Hobblepot Honeywhistle Inklewhistle Jellicoe Kettleworth
    Kindlewick Lillypond Mossberry Muddlefoot Nettlewick Oakenshaw
    Otterby Pettigrew Plumtree Puddleduck Quibbleton Quincewood
    Rambleberry Sassafras Snickelby Snodgrass Thistledown Tootlebury
    Twinkleton Umbergrove Wafflesmith Wigglesworth Wobblesworth
    Yonderberry Ziggleswade
  ].freeze

  # Raw HiBob payload keys that carry a person's name.
  NAME_KEYS = %w[firstName surname displayName].freeze

  # Version tag in the digest input — bump to reshuffle every pseudonym.
  DIGEST_PREFIX = "growthos-dev-whimsy-v1"

  class << self
    # @return [Boolean] whether whimsification applies (development only)
    def enabled?
      Rails.env.development?
    end

    # Gate + transform. Outside development this is a pass-through, so the
    # adapter can call it unconditionally.
    #
    # @param attrs [Hash] mapped Person attributes (see Hris::Hibob::ResponseMapper#call)
    # @return [Hash] attrs with name fields pseudonymised, or attrs untouched
    def call(attrs)
      enabled? ? whimsify(attrs) : attrs
    end

    # Replaces `:name` and every name field inside `:hris_raw_data` with the
    # person's deterministic pseudonym. Never mutates the input.
    #
    # @param attrs [Hash] mapped Person attributes
    # @return [Hash] a new attrs hash with names pseudonymised
    def whimsify(attrs)
      seed = attrs[:external_id].presence || attrs[:email]
      return attrs if seed.blank?

      whimsified = attrs.merge(name: whimsical_name(seed))
      if attrs[:hris_raw_data].is_a?(Hash)
        whimsified[:hris_raw_data] = scrub_raw_data(attrs[:hris_raw_data], seed)
      end
      whimsified
    end

    # The stable whimsical pseudonym for a given HRIS identifier.
    #
    # @param seed [String] stable per-person identifier (HRIS external id)
    # @return [String] e.g. "Clementine Puddleduck"
    def whimsical_name(seed)
      first, last = name_parts(seed)
      "#{first} #{last}"
    end

    private

    # @param seed [String]
    # @return [Array(String, String)] first name and surname
    def name_parts(seed)
      hi, lo = Digest::SHA256.digest("#{DIGEST_PREFIX}:#{seed}").unpack("nn")
      [ FIRST_NAMES[hi % FIRST_NAMES.length], SURNAMES[lo % SURNAMES.length] ]
    end

    # Deep-dups the raw HiBob employee hash and rewrites its name fields —
    # including the manager's inside `work.reportsTo`, seeded by the
    # manager's own id so it matches the manager's own record.
    #
    # @param raw [Hash] raw HiBob employee payload
    # @param seed [String] the employee's own seed
    # @return [Hash]
    def scrub_raw_data(raw, seed)
      scrubbed = raw.deep_dup
      rewrite_name_keys(scrubbed, seed)

      reports_to = scrubbed.dig("work", "reportsTo")
      if reports_to.is_a?(Hash)
        manager_seed = reports_to["id"].presence || reports_to["displayName"]
        rewrite_name_keys(reports_to, manager_seed) if manager_seed.present?
      end

      scrubbed
    end

    # Rewrites the NAME_KEYS present on the given hash in place.
    #
    # @param hash [Hash] a payload fragment carrying name keys
    # @param seed [String]
    def rewrite_name_keys(hash, seed)
      first, last = name_parts(seed)
      hash["firstName"] = first if hash.key?("firstName")
      hash["surname"] = last if hash.key?("surname")
      hash["displayName"] = "#{first} #{last}" if hash.key?("displayName")
    end
  end
end
