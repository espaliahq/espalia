# frozen_string_literal: true

require "json"

# Reads what a WRITE_CATALOGUE=1 test run recorded (see write_catalogue.rb)
# and answers who writes each table, which writes reach a projection's tables
# from outside it, and which write-shaped lines the run never reached.
class WriteCatalogueReport
  DIR = Rails.root.join("tmp/write_catalogue")
  TIMESTAMPS = %w[created_at updated_at].freeze
  ROW_WRITES = %w[insert upsert delete].freeze
  # A text search for persistence calls. It over-matches (Hash#update), and a
  # line it finds may be reached and still write nothing, when a save has no changes.
  PERSISTENCE_CALL = /\.(save!?|update!?|update_all|update_columns?|update_attribute|create!?|insert_all!?|
                       upsert_all|upsert|delete_all|delete_by|destroy!?|destroy_all|destroy_by|touch|touch_all|
                       increment!|decrement!|toggle!|find_or_create_by!?|create_or_find_by!?|first_or_create!?|
                       update_counters|increment_counter)(?=[\s(!]|$)/x
  SEARCHED = %w[app lib].freeze

  Write = Struct.new(:table, :op, :columns, :projection, :site, :count, keyword_init: true) do
    def file = site&.split(":")&.first
    def line = site && site[/\A[^ ]+/]
  end

  def self.load
    rows = Dir[DIR.join("*.json")].flat_map { |path| JSON.parse(File.read(path)) }
    raise "No recorded writes in #{DIR}. Run the suite with WRITE_CATALOGUE=1 first." if rows.empty?

    new(rows)
  end

  # @param rows [Array<Hash>] recorded writes, one hash per distinct write per worker
  def initialize(rows)
    merged = rows.group_by { it.except("count") }.map { |key, group| key.merge("count" => group.sum { it["count"] }) }
    @writes = merged.map { Write.new(**it.transform_keys(&:to_sym)) }
  end

  attr_reader :writes

  # @return [Hash{String => Hash}] per table, the projections that write it,
  #   whether they write its rows, and the columns they update
  def owners
    @owners ||= writes.select(&:projection).group_by(&:table).transform_values do |group|
      { projections: group.map(&:projection).uniq.sort,
        rows: group.any? { ROW_WRITES.include?(it.op) },
        columns: (group.flat_map(&:columns).uniq - TIMESTAMPS).sort }
    end
  end

  # Writes from our code to a table, or a column, a projection writes, made
  # outside that projection; and tables more than one projection writes.
  def findings
    strays = writes.select(&:site).filter_map do |write|
      owner = owners[write.table]
      next unless owner
      next if owner[:projections] == [ write.projection ]

      touched = write.columns - TIMESTAMPS
      reason = if owner[:rows]
        "#{write.op} on a table #{owner[:projections].join(' and ')} writes"
      elsif write.op == "update" && (touched & owner[:columns]).any?
        "updates #{(touched & owner[:columns]).join(', ')}, which #{owner[:projections].join(' and ')} writes"
      elsif write.op == "delete"
        "deletes rows whose columns #{owner[:projections].join(' and ')} writes"
      end
      next unless reason

      { table: write.table, site: write.site, projection: write.projection, reason:, count: write.count }
    end
    shared = owners.select { |_, owner| owner[:projections].size > 1 }.map do |table, owner|
      { table:, site: nil, projection: nil, reason: "written by #{owner[:projections].join(' and ')}", count: 0 }
    end
    shared + strays.sort_by { [ it[:table], it[:site] ] }
  end

  # @return [Hash{String => Array<Write>}] writes to tables no projection writes
  def plain_tables
    writes.reject { owners.key?(it.table) }.group_by(&:table).sort.to_h
  end

  # @return [Array<String>] "path:line" of persistence calls the run never reached
  def unreached
    @unreached ||= persistence_calls - writes.filter_map(&:line)
  end

  def persistence_calls
    @persistence_calls ||= source_files.flat_map do |path|
      File.foreach(path).with_index(1).filter_map do |text, lineno|
        "#{path}:#{lineno}" if !text.lstrip.start_with?("#") && PERSISTENCE_CALL.match?(text)
      end
    end
  end

  # @return [Hash] how much of the code the run reached
  def coverage
    called = persistence_calls.map { it.split(":").first }.uniq
    written = writes.filter_map(&:file).uniq
    { files: source_files.size, files_with_persistence_calls: called.size,
      files_with_a_write: written.size, files_with_calls_but_no_write: (called - written).size,
      persistence_calls: persistence_calls.size, unreached_calls: unreached.size }
  end

  def to_markdown
    [ coverage_section, findings_section, plain_section, unreached_section ].join("\n\n")
  end

  private

  def source_files
    @source_files ||= Dir.chdir(Rails.root) { SEARCHED.flat_map { Dir["#{it}/**/*.{rb,rake}"] }.sort }
  end

  def coverage_section
    "## Coverage\n\n" + coverage.map { |key, value| "- #{key.to_s.tr('_', ' ')}: #{value}" }.join("\n")
  end

  def findings_section
    rows = findings.map { |f| "| #{f[:table]} | #{f[:site] || '-'} | #{f[:projection] || '-'} | #{f[:reason]} | #{f[:count]} |" }
    "## Findings\n\n| Table | Site | Inside | Why | Writes |\n|---|---|---|---|---|\n" + rows.join("\n")
  end

  def plain_section
    tables = plain_tables.map do |table, group|
      sited = group.select(&:site).group_by(&:site).map do |site, at|
        "| #{site} | #{at.map(&:op).uniq.sort.join(', ')} | #{at.flat_map(&:columns).uniq.sort.join(', ')} | #{at.sum(&:count)} |"
      end
      setup = group.reject(&:site).sum(&:count)
      "### #{table}\n\nTest setup writes: #{setup}\n\n| Site | Ops | Columns | Writes |\n|---|---|---|---|\n" + sited.join("\n")
    end
    "## Tables no projection writes\n\n" + tables.join("\n\n")
  end

  def unreached_section
    "## Persistence calls the run never reached\n\n" + unreached.map { "- #{it}" }.join("\n")
  end
end
