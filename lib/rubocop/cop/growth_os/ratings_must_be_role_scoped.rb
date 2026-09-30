# frozen_string_literal: true

module RuboCop
  module Cop
    module GrowthOs
      # Flags an `AssessmentLevelRating` query that never says which role it
      # reads for. A rating is a fact about a person at a capability × level,
      # not about a role (ADR-22), so a reader that counts raw rows picks up
      # cells the assessed role doesn't bind. Every chain rooted at the
      # model must pass through `.within(scope)` — an `Assessments::RoleScope`
      # or a person => scope map — or announce itself with `.across_all_roles`.
      #
      # Exempt by construction: building a record (`new`, `create`, bulk
      # inserts), a single-row lookup that names the cell (`find_by` with both
      # `capability_stable_id:` and `level_ordinal:`), and the class passed as
      # an argument. The projection that writes the table is excluded in
      # `.rubocop.yml`.
      #
      # @example bad
      #   AssessmentLevelRating.for_cycle(cycle_id).where(person_id: ids).count
      #
      # @example good
      #   AssessmentLevelRating.for_cycle(cycle_id).within(scopes_by_person).count
      #   AssessmentLevelRating.across_all_roles.where(person_id: ids)
      #   AssessmentLevelRating.find_by(cycle_id:, person_id:, framework_id:,
      #                                 capability_stable_id:, level_ordinal:)
      class RatingsMustBeRoleScoped < RuboCop::Cop::Base
        MSG =
          "Read AssessmentLevelRating through a role: chain `.within(scope)` with an " \
          "Assessments::RoleScope, or `.across_all_roles` when the answer is about the " \
          "person rather than any one role. See ADR-22."

        SCOPING_METHODS = %i[within across_all_roles].freeze
        CELL_FINDERS = %i[find_by find_by! find_or_initialize_by find_or_create_by find_or_create_by!].freeze
        CELL_KEYS = %i[capability_stable_id level_ordinal].freeze
        NON_READS = %i[
          new build create create! insert_all insert_all! upsert_all upsert_all!
          human_attribute_name model_name table_name column_names
        ].freeze

        def_node_matcher :rating_model?, "(const {nil? cbase} :AssessmentLevelRating)"

        def on_const(node)
          return unless rating_model?(node)

          call = node.parent
          return unless call&.call_type? && call.receiver.equal?(node)
          return if NON_READS.include?(call.method_name)
          return if names_one_cell?(call)
          return if chain_method_names(call).intersect?(SCOPING_METHODS)

          add_offense(call)
        end

        private

        def names_one_cell?(call)
          return false unless CELL_FINDERS.include?(call.method_name)

          keys = call.arguments.select(&:hash_type?).flat_map(&:keys).select(&:sym_type?).map(&:value)
          (CELL_KEYS - keys).empty?
        end

        # Every method called along the chain rooted at `call`, stepping
        # through blocks so `.where(...).tap { }.within(...)` still counts.
        def chain_method_names(call)
          names = [ call.method_name ]
          node = call
          loop do
            parent = node.parent
            if %i[block numblock].include?(parent&.type) && parent.send_node.equal?(node)
              node = parent
            elsif parent&.call_type? && parent.receiver.equal?(node)
              names << parent.method_name
              node = parent
            else
              return names
            end
          end
        end
      end
    end
  end
end
