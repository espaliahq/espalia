# frozen_string_literal: true

require "json"
require "fileutils"

# Records every database write the test suite makes: its table, columns, the
# projection it ran inside (if any), and the nearest call site in app/ or lib/.
# `bin/rails development:write_catalogue` merges the workers' files and reports
# writes to a projection's tables from outside it. Off unless WRITE_CATALOGUE=1.
module WriteCatalogue
  DIR = Rails.root.join("tmp/write_catalogue")
  WRITE = /\A\s*(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"?(\w+)"?/i
  # Written by gems, never by our code.
  INFRASTRUCTURE = /\A(event_store_|solid_|ar_internal_metadata\z|schema_migrations\z)/
  SOURCE_ROOTS = [ Rails.root.join("app").to_s, Rails.root.join("lib").to_s ].freeze

  class << self
    def enabled? = ENV["WRITE_CATALOGUE"] == "1"

    def install!
      @writes = Hash.new(0)
      @mutex = Mutex.new
      ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        record(payload) unless payload[:cached]
      end
      Projections::Registry::REPLAYABLE.each_value { |name| track_projection(name.constantize) }
      ActiveSupport::TestCase.parallelize_teardown { |_worker| dump }
      Minitest.after_run { dump }
    end

    # @return [String, nil] the projection whose code is running on this thread
    def projection = Thread.current[:write_catalogue_projections]&.last

    def within(projection_name)
      stack = (Thread.current[:write_catalogue_projections] ||= [])
      stack.push(projection_name)
      yield
    ensure
      stack.pop
    end

    def dump
      FileUtils.mkdir_p(DIR)
      rows = @mutex.synchronize { @writes.map { |key, count| key.merge(count:) } }
      File.write(DIR.join("#{Process.pid}.json"), JSON.generate(rows))
    end

    private

    def record(payload)
      match = WRITE.match(payload[:sql])
      return unless match
      return if INFRASTRUCTURE.match?(match[2])

      key = { table: match[2], op: operation(match[1], payload[:sql]), columns: columns(payload[:sql]),
              projection:, site: call_site }
      @mutex.synchronize { @writes[key] += 1 }
    end

    def operation(verb, sql)
      return "upsert" if verb.start_with?("INSERT") && sql.match?(/ON CONFLICT[^;]*DO UPDATE/i)

      verb.split.first.downcase
    end

    def columns(sql)
      list = if sql.start_with?("INSERT")
        sql[/\A[^(]*\(([^)]*)\)/, 1]
      elsif sql.start_with?("UPDATE")
        sql[/\bSET\s+(.*?)(?:\s+WHERE\b|\s+RETURNING\b|\z)/mi, 1]&.scan(/(?:\A|,)\s*"?(\w+)"?\s*=/)&.join(",")
      end
      list.to_s.scan(/\w+/).uniq.sort
    end

    # The nearest frame in our own code, so a factory or a test writing a row
    # directly records no site at all.
    def call_site
      frame = caller_locations(4).find { |location| SOURCE_ROOTS.any? { location.path.start_with?(it) } }
      return unless frame

      "#{frame.path.delete_prefix("#{Rails.root}/")}:#{frame.lineno} #{frame.base_label}"
    end

    def track_projection(klass)
      name = klass::PROJECTION_NAME
      klass.prepend(Module.new { define_method(:call) { |event| WriteCatalogue.within(name) { super(event) } } })
      klass.singleton_class.prepend(Module.new do
        define_method(:reset!) { |**options| WriteCatalogue.within(name) { super(**options) } }
      end)
    end
  end
end

WriteCatalogue.install! if WriteCatalogue.enabled?
