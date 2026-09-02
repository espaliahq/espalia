# frozen_string_literal: true

module RuboCop
  module Cop
    module SystemTests
      # Flags the two highest-signal flake-prone interaction patterns in
      # system tests. On starved GitHub-hosted CI runners, Selenium's
      # synthetic pointer click and its modal-handler registration are
      # silently dropped, producing intermittent failures. Three rounds of
      # flake-fixing (PRs #67, #78, #106) converged on the same remedy:
      # dispatch the action synchronously via JavaScript so it bypasses
      # pointer hit-testing entirely.
      #
      # See docs/guidelines/testing.md for the full set of helpers.
      #
      # @example accept_confirm (flagged)
      #   # bad — the click that should trigger the dialog races Capybara's
      #   # modal-handler registration on starved CI
      #   accept_confirm { click_button "Delete" }
      #
      #   # good — stub window.confirm so Turbo resolves it synchronously
      #   auto_confirm { click_button "Delete" }
      #
      # @example clicking a Stimulus-action element (flagged)
      #   # bad — Capybara's pointer click can be dropped
      #   find("[data-action='dropdown#toggle']").click
      #
      #   # good — JS-dispatched click runs the action handler inline
      #   page.execute_script("document.querySelector(\"...\").click()")
      #
      # When a flagged call is genuinely the behaviour under test (e.g. a
      # test that asserts the confirm dialog text), opt out inline:
      #
      #   accept_confirm(/Are you sure/) { click_button "Delete" } # rubocop:disable SystemTests/FlakeProneClick
      #
      # The same escape hatch covers a Selenium ActionBuilder chain —
      # `page.driver.browser.action.send_keys(:escape).perform` is flagged
      # (the send_keys receiver is deliberately unconstrained) even though
      # `press_escape` is not a drop-in replacement for a real key-dispatch
      # chain. No such call exists today; disable inline if one is ever
      # needed.
      #
      # Deliberately narrow: `escape_arg?` recognises only a literal
      # `:escape`, bare or one array level deep. A computed or aliased Esc
      # (`send_keys(key)`, `send_keys(KEYS[:esc])`) is NOT flagged — a
      # low-false-positive posture, not coverage. The `.coderabbit.yaml`
      # path instructions are the intended net for those fuzzier forms.
      class FlakeProneClick < RuboCop::Cop::Base
        MSG_ACCEPT_CONFIRM =
          "Use `auto_confirm` instead of `accept_confirm` for data-turbo-confirm " \
          "submissions — the click can race Capybara's modal-handler registration " \
          "on starved CI. See docs/guidelines/testing.md. Disable inline if the " \
          "dialog text itself is under test."

        MSG_STIMULUS_CLICK =
          "Capybara's pointer click on a Stimulus-action element is dropped on " \
          "starved CI. Dispatch the click via `page.execute_script` (or a helper " \
          "like `open_dropdown` / `expand_matrix_row`). See docs/guidelines/testing.md."

        # Matches `accept_confirm`, `accept_confirm(...)`, `accept_confirm { }`.
        def_node_matcher :accept_confirm?, <<~PATTERN
          (send nil? :accept_confirm ...)
        PATTERN

        MSG_ESCAPE_KEY =
          "Selenium key dispatch needs a focused, interactable target — once a " \
          "modal opens, focus has moved into the dialog and Esc aimed at `body` " \
          "is swallowed, so the `keydown.esc@window` handler never runs. Use " \
          "`press_escape`. See docs/guidelines/testing.md."

        # Matches `.click` whose receiver is `find(<str>)` / `first(<str>)`
        # where the selector literal references a Stimulus `data-action`.
        # The receiver is deliberately unconstrained: a SCOPED find
        # (`row.find("[data-action=…]")`) drops its click exactly like a
        # top-level one, and only matching `nil?` let those through.
        def_node_matcher :stimulus_action_click?, <<~PATTERN
          (send
            (send _ {:find :first}
              ${str dstr} ...)
            :click ...)
        PATTERN

        # Matches EVERY `send_keys` call, on any receiver — the Esc filtering
        # is entirely `escape_arg?`'s job (both are required in `on_send`).
        # Widening this pattern without that guard would flag every
        # `send_keys(:tab)` in the suite.
        def_node_matcher :escape_send_keys?, <<~PATTERN
          (send _ :send_keys ...)
        PATTERN

        def on_send(node)
          add_offense(node, message: MSG_ACCEPT_CONFIRM) if accept_confirm?(node)

          stimulus_action_click?(node) do |selector_node|
            add_offense(node, message: MSG_STIMULUS_CLICK) if stimulus_selector?(selector_node)
          end

          add_offense(node, message: MSG_ESCAPE_KEY) if escape_send_keys?(node) && escape_arg?(node)
        end

        private

        # True when the selector literal mentions a Stimulus action binding.
        def stimulus_selector?(selector_node)
          selector_text(selector_node).include?("data-action")
        end

        # True when any argument is the :escape symbol (bare or in an array,
        # e.g. `send_keys([:shift, :escape])`).
        def escape_arg?(node)
          node.arguments.any? do |arg|
            (arg.sym_type? && arg.value == :escape) ||
              (arg.array_type? && arg.values.any? { |v| v.sym_type? && v.value == :escape })
          end
        end

        # Flattens a str or dstr (interpolated string) node to its literal text.
        def selector_text(node)
          return node.value.to_s if node.str_type?

          node.each_child_node(:str).map(&:value).join
        end
      end
    end
  end
end
