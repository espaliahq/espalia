# frozen_string_literal: true

require "csv"

# A file of actual pay, read in memory and matched against one scenario's map
# ([#323](https://github.com/espaliahq/espalia/issues/323)). Nothing here
# stores, logs or raises with a value: a problem is a line number and a
# reason code, as the uploader has the file and can look the row up.
#
# Each `person` is tried as a person id, then an HRIS employee id, then an
# email, the first that names anyone winning. An email compares
# case-insensitively and exactly otherwise, against the person's own address
# and their account's.
#
# @example
#   upload = TeamPlanning::PayUpload.new(csv: text, basis: "full_time")
#   report = upload.against(map)
#   report.ok? # => true when every row matched and every value is pay
class TeamPlanning::PayUpload
  MAX_BYTES = 1.megabyte
  MAX_ROWS = 5_000
  COLUMNS = %w[person amount currency period].freeze

  # Why a file can't be read at all.
  FILE_PROBLEMS = %w[empty too_large bad_encoding bad_csv missing_column too_many_rows].freeze

  # Why a row can't be written. A row can carry several.
  ROW_PROBLEMS = %w[no_match ambiguous_match not_on_map duplicate_person bad_amount bad_currency bad_period hourly_actual].freeze

  BOM = "\u{FEFF}"

  Failure = Data.define(:line, :codes)
  Match = Data.define(:line, :person_id, :pay)
  Row = Data.define(:line, :person, :amount, :currency, :period)

  # @!attribute problem [String, nil] one of {FILE_PROBLEMS}, when the file can't be read
  # @!attribute line [Integer, nil] where a `bad_csv` file stops parsing
  # @!attribute rows_read [Integer]
  # @!attribute matches [Array<Match>] each row that can be written, in file order
  # @!attribute failures [Array<Failure>] each row that can't, in file order
  # @!attribute missing_ids [Array<String>] the people on the map the file has no row for
  Report = Data.define(:problem, :line, :rows_read, :matches, :failures, :missing_ids) do
    def initialize(line: nil, rows_read: 0, matches: [], failures: [], missing_ids: [], **) = super

    # @return [Boolean] whether every row can be written
    def ok? = problem.nil? && failures.empty? && matches.any?
  end

  # @param plan_id [String]
  # @param scenario_id [String]
  # @param basis [String]
  # @param csv [String] the file's bytes as sent
  # @return [String] an HMAC over all three, under a key only this plan's uploads use
  def self.signature(plan_id:, scenario_id:, basis:, csv:)
    key = Rails.application.key_generator.generate_key("team_planning/pay_upload/#{plan_id}", 32)
    hmac = OpenSSL::HMAC.new(key, "SHA256")
    [ scenario_id, basis ].each { hmac << it.to_s << "\0" }
    hmac << csv.to_s.b
    hmac.hexdigest
  end

  # @param signature [String, nil] as the preview gave it
  # @return [Boolean] whether it signs these exact inputs
  def self.signed?(signature, **inputs)
    ActiveSupport::SecurityUtils.secure_compare(signature.to_s, signature(**inputs))
  end

  # @param csv [String] the file's bytes
  # @param basis [String] one of {TeamPlanning::Events::PlanDataSet::PAY_BASES}, for every row
  def initialize(csv:, basis:)
    @csv = csv.to_s
    @basis = basis
  end

  # @param map [TeamPlanning::Baseline::Map] the scenario as it resolves
  # @return [Report]
  def against(map)
    rows = parsed
    return rows if rows.is_a?(Report)

    on_map = map.people.reject(&:placeholder).to_set(&:id)
    found = matched(rows.map(&:person))
    seen = Set.new
    matches = []
    failures = []
    rows.each do |row|
      person_id, codes = person_for(found, row.person, on_map)
      codes << "duplicate_person" if person_id && !seen.add?(person_id)
      pay, value_codes = pay_for(row)
      codes.concat(value_codes)
      codes.empty? ? matches << Match.new(line: row.line, person_id:, pay:) : failures << Failure.new(line: row.line, codes:)
    end

    Report.new(problem: nil, rows_read: rows.size, matches:, failures:, missing_ids: (on_map - seen).to_a)
  end

  private

  def parsed
    return Report.new(problem: "too_large") if @csv.bytesize > MAX_BYTES

    text = @csv.dup.force_encoding(Encoding::UTF_8)
    return Report.new(problem: "bad_encoding") unless text.valid_encoding?

    text = text.delete_prefix(BOM)
    return Report.new(problem: "empty") if text.strip.empty?

    rows_of(CSV.new(text, headers: true, return_headers: true))
  rescue CSV::MalformedCSVError => e
    Report.new(problem: "bad_csv", line: e.line_number)
  end

  def rows_of(csv)
    columns = column_indexes(csv.shift&.headers || [])
    return Report.new(problem: "missing_column") unless columns

    rows = []
    # CSV#lineno counts records, so a quoted field across lines would push every later line number out.
    next_line = 1 + csv.line.to_s.count("\n")
    loop do
      row = csv.shift or break
      line = next_line
      next_line += csv.line.count("\n")
      next if row.fields.all?(&:blank?)
      return Report.new(problem: "too_many_rows") if rows.size == MAX_ROWS

      rows << Row.new(line:, **columns.transform_values { row[it].to_s.strip })
    end
    rows.empty? ? Report.new(problem: "empty") : rows
  end

  # @return [Hash{Symbol => Integer}, nil] each column's index, nil when one is missing
  def column_indexes(headers)
    names = headers.map { it.to_s.strip.downcase }
    indexes = COLUMNS.to_h { [ it.to_sym, names.index(it) ] }
    indexes unless indexes.value?(nil)
  end

  # @return [Hash{Symbol => Hash{String => Set<String>}}] each tier's values, to the people they name
  def matched(values)
    tenant_id = ActsAsTenant.current_tenant.id
    people = Person.remembered.where(tenant_id:)
    uuids = values.map(&:downcase).grep(Operations::TeamPlanning::PlanWrite::UUID_RE)
    emails = values.map(&:downcase).select { it.include?("@") }
    {
      id: grouped(people.where(id: uuids).pluck(:id, :id)),
      external_id: grouped(people.where(external_id: values).pluck(:external_id, :id)),
      email: grouped(people.where("LOWER(people.email) IN (?)", emails).pluck(Arel.sql("LOWER(people.email)"), :id) +
                     people.joins(:user).where("LOWER(users.email) IN (?)", emails)
                           .pluck(Arel.sql("LOWER(users.email)"), :id))
    }
  end

  def grouped(pairs) = pairs.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) { |(value, id), by| by[value] << id }

  def person_for(found, value, on_map)
    ids = found[:id].fetch(value.downcase, nil).presence || found[:external_id].fetch(value, nil).presence ||
          found[:email].fetch(value.downcase, nil).presence || Set.new
    return [ nil, [ "no_match" ] ] if ids.empty?
    return [ nil, [ "ambiguous_match" ] ] if ids.size > 1
    return [ nil, [ "not_on_map" ] ] unless on_map.include?(ids.first)

    [ ids.first, [] ]
  end

  def pay_for(row)
    codes = []
    codes << "bad_amount" unless row.amount.match?(TeamPlanning::Events::PlanDataSet::PAY_AMOUNT) && row.amount.to_r.positive?
    codes << "bad_currency" unless Currency::CODES.include?(Currency::NORMALIZE.call(row.currency))
    codes << "bad_period" unless PayBand::PERIODS.include?(row.period.downcase)
    codes << "hourly_actual" if row.period.downcase == "hour" && @basis == "actual"
    return [ nil, codes ] if codes.any?

    [ TeamPlanning::Events::PlanDataSet.pay!(amount: row.amount, currency: row.currency, period: row.period.downcase, basis: @basis), codes ]
  end
end
