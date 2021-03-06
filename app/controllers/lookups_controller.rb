class LookupsController < ApplicationController
  def by_base_path
    # return content_ids for content that is visible on the live site
    # withdrawn items are still visible
    states = %w(published unpublished)
    base_paths = params.fetch(:base_paths)

    scope = Edition.left_outer_joins(:unpublishing)

    # where not in (..) does not return records that where the field is null
    scope = scope.where(unpublishings: { type: nil }).or(
      scope.where.not(unpublishings: { type: params.fetch(:exclude_unpublishing_types, %w{vanish redirect gone}) })
    )

    scope = scope.with_document
      .where(state: states, content_store: 'live', base_path: base_paths)
      .where.not(document_type: params.fetch('exclude_document_types', %w{gone redirect}))

    base_paths_and_content_ids = scope.distinct.pluck(:base_path, 'documents.content_id')

    response = Hash[base_paths_and_content_ids]
    render json: response
  end
end
