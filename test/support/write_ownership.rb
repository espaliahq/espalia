# frozen_string_literal: true

require "yaml"

# Reads config/write_ownership.yml, which says who may write each table, and
# checks it against the schema and against what a WRITE_CATALOGUE=1 run recorded.
class WriteOwnership
  PATH = Rails.root.join("config/write_ownership.yml")
  KEYS = %w[owner columns reason writers].freeze
  # Rails' own bookkeeping, which the schema doesn't list.
  RAILS_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  Entry = Struct.new(:table, :owner, :columns, :reason, :writers, keyword_init: true) do
    def projection = (owner unless %w[event_store plain].include?(owner))
  end

  # @param path [Pathname]
  # @return [WriteOwnership]
  def self.load(path = PATH) = new(YAML.safe_load_file(path))

  # @param data [Hash{String => Hash}] one entry per table
  def initialize(data)
    @data = data
    @entries = data.to_h do |table, entry|
      entry = entry.to_h
      [ table, Entry.new(table:, owner: entry["owner"], columns: Array(entry["columns"]), reason: entry["reason"],
                         writers: Array(entry["writers"])) ]
    end
  end

  # @param table [String]
  # @return [Entry, nil]
  def [](table) = @entries[table]

  # @param tables [Array<String>] the database's tables
  # @param projections [Array<String>] every projection's name
  # @return [Array<String>] what is wrong with the declaration itself
  def declaration_problems(tables:, projections:)
    tables -= RAILS_TABLES
    undeclared = (tables - @entries.keys).map { "#{it}: no entry. Say who writes it in #{PATH.basename}." }
    gone = (@entries.keys - tables).map { "#{it}: no such table. Remove its entry." }
    undeclared + gone + @entries.values.flat_map { entry_problems(it, projections) }
  end

  # @param report [WriteCatalogueReport]
  # @return [Array<Hash>] each recorded write the declaration doesn't allow:
  #   table, site, projection and why, once per table, site and projection
  def violations(report)
    found = report.writes.filter_map do |write|
      reason = violation(write)
      { table: write.table, site: write.site, projection: write.projection, reason: } if reason
    end
    found.uniq.sort_by { [ it[:table], it[:site].to_s, it[:projection].to_s ] }
  end

  private

  def entry_problems(entry, projections)
    name = entry.table
    shape = @data[name].is_a?(Hash) ? @data[name].keys - KEYS : [ "(not a mapping)" ]
    problems = shape.map { "#{name}: unknown key #{it}" }
    problems << "#{name}: owner must be a projection, event_store or plain" if entry.owner.blank?
    problems << "#{name}: owner #{entry.owner} is no projection" if entry.projection && !projections.include?(entry.projection)
    problems << "#{name}: only a projection owns columns" if entry.columns.any? && !entry.projection
    problems << "#{name}: say in reason why it is plain, or why the writers write it" if needs_reason?(entry)
    problems + entry.writers.reject { Rails.root.join(it).file? }.map { "#{name}: writer #{it} is no file" }
  end

  def needs_reason?(entry)
    entry.reason.blank? && (entry.owner == "plain" || entry.writers.any? || entry.columns.any?)
  end

  def violation(write)
    return unless write.site || write.projection

    entry = self[write.table]
    return "no entry for the table" unless entry
    return if entry.owner == "event_store"

    write.projection ? projection_violation(entry, write) : writer_violation(entry, write)
  end

  # A projection writes only its own table, and, where it owns some columns,
  # only those.
  def projection_violation(entry, write)
    return "written inside #{write.projection}, which doesn't own it" unless write.projection == entry.projection
    return if entry.columns.empty? || write.op == "delete"

    extra = written_columns(write) - entry.columns - WriteCatalogueReport::TIMESTAMPS
    "#{write.projection} writes #{extra.join(', ')}, which it isn't declared to own" if extra.any?
  end

  # A write with no site came from a test. Any other must come from a named file.
  def writer_violation(entry, write)
    file = write.site.split(":").first
    "#{file} writes it, and isn't one of its writers" unless entry.writers.include?(file)
  end

  def written_columns(write)
    write.op == "upsert" ? Array(write.updates) : write.columns
  end
end
