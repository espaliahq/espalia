# frozen_string_literal: true

require "digest"
require "set"
require "yaml"

module RuboCop
  module Cop
    module Espalia
      # Flags a persistence call in a file that `config/write_ownership.yml`
      # names as no table's writer. The declaration is the one list of who may
      # write what; this reads it at load, so nothing here repeats it.
      #
      # The match is by method name, so it can't tell which table a call
      # writes, and a named file may write any table. The recorded check in
      # CI (`write_ownership:check`) holds each write to its own table.
      # `delete`, `insert` and `update` count only on a constant, as
      # `session.delete` and `turbo_stream.update` write nothing. A `save`
      # given a positional argument isn't ActiveRecord's, which takes only
      # keyword options.
      #
      # @example bad
      #   # in a file the declaration doesn't name
      #   tenant.update!(time_zone: zone)
      #
      # @example good
      #   # name the file among the table's writers, with the reason
      #   tenants:
      #     owner: plain
      #     reason: ...
      #     writers:
      #       - app/operations/operations/tenants/set_time_zone.rb
      class WritesMustBeDeclared < RuboCop::Cop::Base
        MSG =
          "`%<method>s` writes the database, and config/write_ownership.yml names this file " \
          "as no table's writer. Name it among the table's writers, with the reason, or move " \
          "the write behind the table's owner. See docs/architecture/direct-writes.md."

        WRITES = %i[
          create create! create_or_find_by create_or_find_by! find_or_create_by find_or_create_by!
          save save! update! update_attribute update_column update_columns update_all
          destroy destroy! destroy_all delete_all insert! insert_all insert_all!
          upsert upsert! upsert_all touch increment! decrement! toggle!
        ].to_set.freeze
        CONSTANT_ONLY = %i[delete insert update].to_set.freeze
        KEYWORD_ONLY = %i[save save!].to_set.freeze

        ROOT = File.expand_path("../../../..", __dir__)
        DECLARATION = File.join(ROOT, "config/write_ownership.yml")

        # @param path [String] the declaration
        # @return [Set<String>] every file any entry names, relative to the root
        def self.declared_writers(path = DECLARATION)
          YAML.safe_load_file(path).values.flat_map do |entry|
            entry = entry.to_h
            Array(entry["writers"]) + Array(entry["column_writers"])
          end.to_set
        end

        # A file's cached result must go when the declaration changes, or a
        # file dropped from it keeps passing.
        def external_dependency_checksum
          Digest::SHA256.file(DECLARATION).hexdigest
        end

        def on_new_investigation
          @declared = self.class.declared_writers.include?(relative_path)
        end

        def on_send(node)
          return if @declared || node.receiver.nil?
          return unless write?(node)

          add_offense(node.loc.selector, message: format(MSG, method: node.method_name))
        end
        alias on_csend on_send

        private

        def write?(node)
          name = node.method_name
          return node.receiver.const_type? if CONSTANT_ONLY.include?(name)
          return false if KEYWORD_ONLY.include?(name) && positional_argument?(node)

          WRITES.include?(name)
        end

        def positional_argument?(node)
          node.arguments.any? { !it.hash_type? && !it.block_pass_type? }
        end

        def relative_path
          processed_source.file_path.to_s.delete_prefix("#{ROOT}/")
        end
      end
    end
  end
end
