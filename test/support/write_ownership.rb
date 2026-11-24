# frozen_string_literal: true

require "yaml"

# Reads config/write_ownership.yml, which says who may write each table, and
# checks it against the schema and against what a WRITE_CATALOGUE=1 run recorded.
class WriteOwnership
  PATH = Rails.root.join("config/write_ownership.yml")
  KEYS = %w[owner columns reason writers column_writers].freeze
  # Rails' own bookkeeping, which the schema doesn't list.
  RAILS_TABLES = %w[ar_internal_metadata schema_migrations].freeze
  # The recorder keeps only sites under these.
  SOURCE_DIRS = %w[app/ lib/].freeze

  # One table's declaration.
  Entry = Struct.new(:table, :owner, :columns, :reason, :writers, :column_writers, keyword_init: true) do
    # @return [String, nil] the owning projection's name, if a projection owns the table
    def projection = (owner unless %w[event_store plain].include?(owner))
  end

  # @param path [Pathname]
  # @return [WriteOwnership]
  def self.load(path = PATH)
    keys = YAML.parse_file(path).root.children.each_slice(2).map { it.first.value }
    new(YAML.safe_load_file(path), keys)
  end

  # @param data [Hash{String => Hash}] one entry per table
  # @param declared [Array<String>] the file's top-level keys, repeats kept, which
  #   YAML folds into one
  def initialize(data, declared = data.keys)
    @data = data
    @declared = declared
    @entries = data.to_h do |table, entry|
      entry = entry.to_h
      [ table, Entry.new(table:, owner: entry["owner"], columns: Array(entry["columns"]), reason: entry["reason"],
                         writers: Array(entry["writers"]), column_writers: Array(entry["column_writers"])) ]
    end
  end

  # @param table [String]
  # @return [Entry, nil]
  def [](table) = @entries[table]

  # @param tables [Hash{String => Array<String>}] each database table's columns
  # @param projections [Array<String>] every projection's name
  # @return [Array<String>] what is wrong with the declaration itself
  def declaration_problems(tables:, projections:)
    tables = tables.except(*RAILS_TABLES)
    twice = @declared.tally.select { |_, count| count > 1 }.keys.map { "#{it}: declared twice. Merge its entries." }
    undeclared = (tables.keys - @entries.keys).map { "#{it}: no entry. Say who writes it in #{PATH.basename}." }
    gone = (@entries.keys - tables.keys).map { "#{it}: no such table. Remove its entry." }
    twice + undeclared + gone + @entries.values.flat_map { entry_problems(it, projections, tables[it.table]) }
  end

  # @param report [WriteCatalogueReport]
  # @return [Array<Hash>] each recorded write the declaration doesn't allow:
  #   table, file, projection and why, once per table, file and projection
  def violations(report)
    found = report.writes.filter_map do |write|
      reason = violation(write)
      { table: write.table, file: file_of(write), projection: write.projection, reason: } if reason
    end
    found.uniq.sort_by { [ it[:table], it[:file].to_s, it[:projection].to_s, it[:reason] ] }
  end

  private

  def entry_problems(entry, projections, columns)
    name = entry.table
    shape = @data[name].is_a?(Hash) ? @data[name].keys - KEYS : [ "(not a mapping)" ]
    problems = shape.map { "#{name}: unknown key #{it}" }
    problems << "#{name}: owner must be a projection, event_store or plain" if entry.owner.blank?
    problems << "#{name}: owner #{entry.owner} is no projection" if entry.projection && !projections.include?(entry.projection)
    problems << "#{name}: only a projection owns columns" if entry.columns.any? && !entry.projection
    problems << "#{name}: column_writers need the columns a projection owns" if entry.column_writers.any? && entry.columns.empty?
    problems += (entry.columns - Array(columns)).map { "#{name}: no column #{it}" } if columns
    problems << "#{name}: say in reason why it is plain, or why the writers write it" if needs_reason?(entry)
    problems + (entry.writers + entry.column_writers).uniq.filter_map { file_problem(name, it) }
  end

  def file_problem(name, path)
    return "#{name}: writer #{path} is outside app/ and lib/" unless path.start_with?(*SOURCE_DIRS)

    "#{name}: writer #{path} is no file" unless Rails.root.join(path).file?
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
  # only those, and no whole rows. An upsert's inserted columns count too.
  def projection_violation(entry, write)
    return "written inside #{write.projection}, which doesn't own it" unless write.projection == entry.projection
    return if entry.columns.empty?
    return "#{write.projection} deletes rows, though it owns only some columns" if write.op == "delete"

    extra = write.columns - entry.columns - WriteCatalogueReport::TIMESTAMPS
    "#{write.projection} writes #{extra.join(', ')}, which it isn't declared to own" if extra.any?
  end

  # A write with no site came from a test. Any other must come from a named file,
  # and only a column writer may change a column the projection owns. An insert
  # names every column, set or not, so only updates count.
  def writer_violation(entry, write)
    file = file_of(write)
    return "#{file} writes it, and isn't one of its writers" unless entry.writers.include?(file)
    return if write.op == "insert" || entry.column_writers.include?(file)

    owned = written_columns(write) & entry.columns
    "#{file} writes #{owned.join(', ')}, which #{entry.projection} owns" if owned.any?
  end

  def file_of(write) = write.site&.split(":")&.first

  def written_columns(write)
    write.op == "upsert" ? Array(write.updates) : write.columns
  end
end
