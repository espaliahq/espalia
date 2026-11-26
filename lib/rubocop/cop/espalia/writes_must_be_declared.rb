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
      # `update` counts on any receiver but the request's and the view's own
      # objects (`session`, `turbo_stream` and the rest of NON_RECORDS) and a
      # literal. `delete` and `insert` count only on a constant or a query
      # built from one (`Person.where(...).delete`), as `ids.delete(id)` writes
      # nothing; on an association they look like an array's, so they pass. A `save`
      # given a positional argument isn't ActiveRecord's, which takes only
      # keyword options.
      #
      # A projection writes only its own tables, so a file under a
      # `projections/` directory or `app/read_models` passes by its path: the
      # recorded check holds it to its tables. A command on an aggregate the
      # repository yields (`@repository.with_plan(id) { |plan| plan.create }`)
      # records an event, not a row, so it passes too.
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
          upsert upsert! upsert_all touch touch_all increment! decrement! toggle!
          update_attribute! delete_by destroy_by first_or_create first_or_create!
          update_counters increment_counter decrement_counter reset_counters
        ].to_set.freeze
        CONSTANT_ONLY = %i[delete insert].to_set.freeze
        NON_RECORDS = %i[turbo_stream session cookies flash params headers].to_set.freeze
        QUERIES = %i[
          all where not rewhere find find_by find_by! first last take sole find_sole_by
          joins left_joins left_outer_joins includes preload eager_load references
          order reorder limit offset distinct lock readonly unscoped merge none
        ].to_set.freeze
        KEYWORD_ONLY = %i[save save!].to_set.freeze

        BY_CONVENTION = %r{\A(app/read_models/|.*/projections/)}
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

        # Read once per lint run, and again only if the file changes during it.
        # @return [Set<String>] the declared writers
        def self.current_writers
          stamp = File.mtime(DECLARATION)
          @current_writers = nil unless @stamp == stamp
          @stamp = stamp
          @current_writers ||= declared_writers
        end

        # A file's cached result must go when the declaration changes, or a
        # file dropped from it keeps passing.
        # @return [String] the declaration's digest
        def external_dependency_checksum
          Digest::SHA256.file(DECLARATION).hexdigest
        end

        # @return [void]
        def on_new_investigation
          @declared = relative_path.match?(BY_CONVENTION) || self.class.current_writers.include?(relative_path)
        end

        # @param node [RuboCop::AST::SendNode]
        # @return [void]
        def on_send(node)
          return if @declared || node.receiver.nil?
          return unless write?(node)
          return if aggregate_command?(node)

          add_offense(node.loc.selector, message: format(MSG, method: node.method_name))
        end
        alias on_csend on_send

        private

        def write?(node)
          name = node.method_name
          return !non_record?(node.receiver) if name == :update
          return model_query?(node.receiver) if CONSTANT_ONLY.include?(name)
          return false if KEYWORD_ONLY.include?(name) && positional_argument?(node)

          WRITES.include?(name)
        end

        def aggregate_command?(node)
          name = node.receiver.lvar_type? && node.receiver.children.first
          name && node.each_ancestor(:block).any? do |block|
            yielder = block.send_node
            yielder.receiver&.ivar_type? && yielder.receiver.children.first == :@repository &&
              yielder.method_name.start_with?("with_") && block.argument_list.map(&:name).include?(name)
          end
        end

        def non_record?(receiver)
          return true if receiver.hash_type? || receiver.array_type?

          name = receiver.lvar_type? ? receiver.children.first : (receiver.method_name if receiver.send_type? && receiver.receiver.nil?)
          NON_RECORDS.include?(name)
        end

        def model_query?(receiver)
          receiver = receiver.receiver while receiver&.send_type? && QUERIES.include?(receiver.method_name)
          receiver&.const_type?
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
