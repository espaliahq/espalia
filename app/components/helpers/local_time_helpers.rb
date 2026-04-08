# frozen_string_literal: true

# Phlex adapter for the local_time gem's view helpers.
#
# local_time_helper.rb defines `local_time`, `local_date`, `local_time_ago`,
# and `local_relative_time` — all of which return HTML-safe <time> tags
# meant to be rendered directly. We register them as output helpers so
# Phlex routes them through its own output buffer rather than returning
# the string (which would double-escape the markup).
#
# Usage:
#
#   class Views::Foo < Views::Base
#     def view_template
#       local_time(@post.published_at)
#       local_time_ago(@post.updated_at)
#     end
#   end
#
# Included in Components::Base so every view and component gets it.
#
# @see https://www.phlex.fun/rails/helpers
# @see https://github.com/basecamp/local_time
#
module Components::Helpers::LocalTimeHelpers
  extend Phlex::Rails::HelperMacros

  register_output_helper def local_time(...) = nil
  register_output_helper def local_date(...) = nil
  register_output_helper def local_relative_time(...) = nil
  register_output_helper def local_time_ago(...) = nil
end
