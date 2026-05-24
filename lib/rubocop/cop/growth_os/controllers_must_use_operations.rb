# frozen_string_literal: true

module RuboCop
  module Cop
    module GrowthOs
      # Flags controller actions that instantiate a domain CommandHandler
      # directly. Controllers and the MCP server must dispatch through the
      # shared `Operations::*` layer so functionality parity stays in
      # lockstep — see `app/operations/base.rb` and the MCP design doc.
      #
      # Existing controllers are grandfathered via the `Exclude:` list in
      # `.rubocop.yml`. When porting one to an Operation, remove it from
      # that list in the same PR.
      #
      # @example bad
      #   # in app/controllers/foo_controller.rb
      #   Frameworks::CommandHandler.new.add_capability(...)
      #
      # @example good
      #   Operations::Frameworks::AddCapability.call(
      #     context: pundit_user,
      #     params: capability_params
      #   )
      class ControllersMustUseOperations < RuboCop::Cop::Base
        MSG =
          "Controllers must dispatch writes through Operations::* (shared with the " \
          "MCP server), not %<handler>s directly. If this controller is mid-migration, " \
          "add it to the Exclude: list under GrowthOs/ControllersMustUseOperations in " \
          ".rubocop.yml. See app/operations/base.rb."

        # Matches `<Anything>::CommandHandler.new`. Captures the const node so
        # the message can name the specific handler in the offense text.
        def_node_matcher :command_handler_new?, <<~PATTERN
          (send $(const _ :CommandHandler) :new ...)
        PATTERN

        def on_send(node)
          command_handler_new?(node) do |const_node|
            add_offense(node, message: format(MSG, handler: const_source(const_node)))
          end
        end

        private

        # Reconstructs the full namespaced const reference (e.g. "Frameworks::CommandHandler")
        # for the offense message.
        def const_source(const_node)
          const_node.source
        end
      end
    end
  end
end
