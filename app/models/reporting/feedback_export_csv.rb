# frozen_string_literal: true

# Encodes a {Operations::Reporting::FeedbackExport} result as the CSV file a
# tenant admin downloads.
#
# The file opens cleanly in Excel: it starts with a UTF-8 byte-order mark (or
# Excel reads "→" and accented names as mojibake), and any cell that starts
# like a formula is prefixed with an apostrophe, because the cells hold text
# people typed and a spreadsheet would otherwise run `=HYPERLINK(...)` typed
# into a piece of feedback (OWASP "CSV injection").
#
# @example
#   csv = Reporting::FeedbackExportCsv.new(export)
#   send_data csv.to_s, filename: csv.filename
class Reporting::FeedbackExportCsv
  BYTE_ORDER_MARK = "﻿"
  FORMULA_PREFIX = /\A[=+\-@\t\r]/

  # @param export [Hash] the Operation's result: `cycle:`, `period:`, `columns:`, `rows:`
  def initialize(export)
    @export = export
  end

  # @return [String] the whole file, header row first
  def to_s
    BYTE_ORDER_MARK + CSV.generate do |csv|
      csv << @export[:columns].pluck(:label)
      @export[:rows].each do |row|
        csv << @export[:columns].map { |column| neutralise(row[column[:key].to_sym]) }
      end
    end
  end

  # @param now [Time]
  # @return [String] e.g. "growthos-feedback-export-q3-2026-2026-09-20261002T093000Z.csv"
  def filename(now: Time.current)
    slug = @export.dig(:cycle, :name).to_s.parameterize.presence || "cycle"
    period = @export.dig(:period, :month) || "all"
    "growthos-feedback-export-#{slug}-#{period}-#{now.utc.strftime('%Y%m%dT%H%M%SZ')}.csv"
  end

  private

  def neutralise(value)
    value.is_a?(String) && FORMULA_PREFIX.match?(value) ? "'#{value}" : value
  end
end
