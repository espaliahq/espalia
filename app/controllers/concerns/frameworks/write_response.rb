# frozen_string_literal: true

# ONE write-response contract for every edit-mode explorer write.
#
# Before this, "I changed something" had seven different outcomes: a silent
# frame swap, a Turbo Stream append, a **full page reload** with a Rails flash
# (add capability / expectation / category / level, archive capability /
# category / illustration — 7.8 MB, scroll position and the open expanded row
# gone), a **native `confirm()` then a full reload** (archive illustration), a
# DOM move, or a **whole-matrix re-fetch** (reorder capability / category —
# ~950 KB and seconds of client time; Hard-Won Lesson 23).
#
# Now every write answers a Turbo Stream that touches exactly the rows it
# changed, plus one toast. Only **Publish** stays a full navigation, and
# `matrix#refresh` survives only for the documented non-surgical suggestion-
# resolution fallback and for org-structure edits that genuinely change the
# matrix *header* (a new level adds a column to every row).
#
# The addressable units, and why each is the right grain:
#
# | Unit | Anchor | Written by |
# |---|---|---|
# | Capability | `capability-row-<id>` (compact `<tr>`) | add · archive |
# | Category | `category-group-<id>` (`<tbody>`) | add · archive · reorder |
# | Cell | `cell-<capability_id>-<ordinal>` (`<td>`) | add expectation |
# | Draft status | `framework-draft-badge` / `framework-publish-action` | every shape-changing write |
# | Toast | `framework-write-status` | every write |
#
# Requires `@framework` (a {FrameworkState::Framework}) and the including
# controller to `include Frameworks::SuggestionAuthority` (for
# {Frameworks::ExplorerMatrix}).
module Frameworks::WriteResponse
  extend ActiveSupport::Concern

  included do
    include Frameworks::ExplorerMatrix
  end

  private

  # ── The response itself ──

  # Renders the write's streams. Errors ride the SAME region at 422 rather than
  # redirecting: a refused write must never cost the user their scroll position
  # or their open expanded row. Turbo's StreamObserver claims a turbo-stream
  # response on `turbo:before-fetch-response` whatever the status, so a 422
  # stream is processed in place exactly like a 200 one.
  #
  # @param streams [Array] turbo_stream fragments
  def render_write_streams(streams, status: :ok)
    render turbo_stream: streams.compact, status: status
  end

  # The one-line failure response — toast only, nothing else touched.
  def render_write_error(message)
    render_write_streams([ toast_stream(message, tone: :error) ], status: :unprocessable_content)
  end

  # ── Toast ──

  # @param message [String] user-facing sentence; the copy must distinguish
  #   applied ("Added …") from proposed ("Proposed …"), since the
  #   editing/suggesting toggle plus the viewer's authority decide which
  #   happened and nothing else on screen says so.
  # @param tone [Symbol] :ok or :error
  # @return [Turbo::Streams::TagBuilder]
  def toast_stream(message, tone: :ok)
    turbo_stream.update(
      Views::Frameworks::Explorer::WriteStatus::REGION_ID,
      render_to_string(
        Views::Frameworks::Explorer::WriteStatusMessage.new(message: message, tone: tone),
        layout: false
      )
    )
  end

  # ── Header draft status ──

  # The `vN draft` pill and the Publish button both sit OUTSIDE the matrix
  # frame, so a shape-changing write (which auto-opens a draft) has to stream
  # them or the header silently lies until the next full load.
  #
  # @return [Array] two turbo_stream fragments
  def draft_status_streams
    framework = @framework.reload
    can_publish = policy(framework).publish?
    [
      turbo_stream.replace(
        Views::Frameworks::Explorer::DraftStatus::BADGE_ID,
        draft_status_html(framework, :badge, visible: true)
      ),
      turbo_stream.replace(
        Views::Frameworks::Explorer::DraftStatus::PUBLISH_ID,
        draft_status_html(framework, :publish, visible: can_publish,
                          publishing: can_publish && FrameworkPublication.publishing?(framework))
      )
    ]
  end

  def draft_status_html(framework, slot, visible:, publishing: false)
    render_to_string(
      Views::Frameworks::Explorer::DraftStatus.new(
        framework: framework, slot: slot, visible: visible, publishing: publishing
      ),
      layout: false
    )
  end

  # ── Matrix fragments ──

  # The edit-mode matrix data for THIS request's scope (roles / track / search
  # ride on the form via the `tree-scope-fields` controller), memoised so one
  # response can render several fragments from one build. Always re-read after
  # the write — the graph snapshot is rewritten in the write's transaction, and
  # a draft-added entity exists only there (Hard-Won Lesson 17).
  #
  # @return [Hash]
  def write_matrix_data
    @write_matrix_data ||= load_explorer_matrix(mode: :edit).last
  end

  # @param capability_id [String]
  # @return [Hash, nil] the builder's data for that capability, or nil when it
  #   is out of the viewer's current scope (a role filter can hide a capability
  #   the write just created — the toast still lands, the grid catches up on the
  #   next render)
  def write_capability_data(capability_id)
    write_matrix_data[:categories]
      .flat_map { |category| category[:capabilities] }
      .find { |data| data[:capability].capability_id == capability_id }
  end

  # @param category_id [String]
  # @return [Hash, nil] the builder's data for that category
  def write_category_data(category_id)
    write_matrix_data[:categories].find { |data| data[:category].category_id == category_id }
  end

  # Inserts a just-added capability's compact + placeholder expanded rows
  # immediately before its category's "+ Add capability" row (always the last
  # row of the group). Nothing else in the grid moves, so an expanded row open
  # elsewhere — and the scroll position — survive.
  #
  # @return [Array] one turbo_stream fragment, or [] when out of scope
  def capability_insert_streams(capability_id, category_id)
    data = write_capability_data(capability_id)
    return [] unless data

    [ turbo_stream.before(
      Views::Frameworks::Explorer::MatrixCategoryGroup.add_capability_row_id(category_id),
      capability_row_html(data, include_expanded_row: true)
    ) ]
  end

  # Replaces just the compact row (struck through + "Pending archive" after a
  # direct archive; wiggled after a proposal). The hidden expanded row is left
  # alone deliberately: replacing it would discard content the user may have
  # already loaded, and its strikethrough is cosmetic — it re-fetches fresh on
  # its next expand.
  #
  # @return [Array] one turbo_stream fragment, or [] when out of scope
  def capability_replace_streams(capability_id)
    data = write_capability_data(capability_id)
    return [] unless data

    [ turbo_stream.replace(
      Views::Frameworks::Explorer::MatrixRow.compact_row_id(capability_id),
      capability_row_html(data, include_expanded_row: false)
    ) ]
  end

  def capability_row_html(data, include_expanded_row:)
    render_to_string(
      Views::Frameworks::Explorer::MatrixRow.new(
        capability_data: data,
        merged_levels: write_matrix_data[:merged_levels],
        selected_role_ids: parse_role_ids,
        framework_id: @framework.framework_id,
        mode: :edit,
        search_query: resolved_search_query,
        include_expanded_row: include_expanded_row,
        **viewer_matrix_flags(:edit)
      ),
      layout: false
    )
  end

  # Appends a just-added category's `<tbody>` group to the matrix table. A new
  # category sorts last (nil ordinal LAST), so append is the right position.
  #
  # @return [Array] one turbo_stream fragment, or [] when the matrix isn't
  #   rendering a table at all (no levels selected / no matches)
  def category_append_streams(category_id)
    data = write_category_data(category_id)
    return [] unless data

    [ turbo_stream.append(
      Views::Frameworks::Explorer::Matrix::TABLE_ID,
      category_group_html(data)
    ) ]
  end

  def category_group_html(data)
    render_to_string(
      Views::Frameworks::Explorer::MatrixCategoryGroup.new(
        category_data: data,
        merged_levels: write_matrix_data[:merged_levels],
        selected_role_ids: parse_role_ids,
        framework_id: @framework.framework_id,
        mode: :edit,
        search_query: resolved_search_query,
        **viewer_matrix_flags(:edit)
      ),
      layout: false
    )
  end

  # Replaces one capability × level `<td>` — the grain an authored expectation
  # changes (empty affordance → rendered expectation, or → a pending ghost).
  #
  # @return [Array] one turbo_stream fragment, or [] when out of scope. A cell
  #   with no data under this scope is deliberately NOT streamed: the write's
  #   form carries the scope read at SUBMIT time, so a role filter changed while
  #   the editor was open can land the write in a scope where the cell is no
  #   longer applicable — and replacing it with the un-addressable em-dash cell
  #   would leave nothing for a later write to target.
  def cell_replace_streams(capability_id, ordinal)
    data = write_capability_data(capability_id)
    return [] unless data && data[:cells][ordinal]

    [ turbo_stream.replace(
      Views::Frameworks::Explorer::MatrixCell.cell_id(capability_id, ordinal),
      render_to_string(
        Views::Frameworks::Explorer::MatrixCell.new(
          cell_data: data[:cells][ordinal],
          ordinal: ordinal,
          framework_id: @framework.framework_id,
          mode: :edit,
          search_query: resolved_search_query,
          capability_name: data[:capability].name,
          current_person_id: viewer_matrix_flags(:edit)[:current_person_id],
          approval_authority: viewer_matrix_flags(:edit)[:approval_authority]
        ),
        layout: false
      )
    ) ]
  end
end
