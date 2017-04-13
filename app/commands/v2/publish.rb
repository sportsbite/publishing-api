require 'gds_api/asset_manager'

module Commands
  module V2
    class Publish < BaseCommand
      def call
        validate

        publish_edition

        if downstream
          after_transaction_commit do
            send_downstream_live
            send_downstream_draft if access_limit
          end
        end

        Success.new(content_id: content_id)
      end

    private

      def publish_edition
        delete_change_notes unless update_type == "major"
        previous_item.supersede if previous_item

        unless edition.pathless?
          redirect_old_base_path
          clear_published_items_of_same_locale_and_base_path
        end

        render_pdf if html_publication?
        set_public_updated_at
        set_first_published_at
        edition.publish
        remove_access_limit
        create_publish_action
        create_change_note if payload[:update_type].present?
      end

      def orphaned_content_ids
        return [] unless previous_item
        previous_links = previous_item.links.map(&:target_content_id)
        current_links = edition.links.map(&:target_content_id)
        previous_links - current_links
      end

      def create_publish_action
        Action.create_publish_action(edition, document.locale, event)
      end

      def create_change_note
        ChangeNote.create_from_edition(payload, edition)
      end

      def access_limit
        @_access_limit ||= AccessLimit.find_by(edition: edition)
      end

      def remove_access_limit
        access_limit.try(:destroy)
      end

      def validate
        no_draft_item_exists unless edition
        validate_update_type
        check_version_and_raise_if_conflicting(document, previous_version_number)
      end

      def update_type
        @update_type ||= payload[:update_type] || edition.update_type
      end

      def edition
        document.draft
      end

      def previous_item
        document.published_or_unpublished
      end

      def redirect_old_base_path
        return unless previous_item
        previous_base_path = previous_item.base_path

        if previous_base_path != edition.base_path
          publish_redirect(previous_base_path, document.locale)
        end
      end

      def no_draft_item_exists
        if already_published?
          message = "Cannot publish an already published edition"
          raise_command_error(400, message, fields: {})
        else
          message = "Item with content_id #{content_id} and locale #{locale} does not exist"
          raise_command_error(404, message, fields: {})
        end
      end

      def validate_update_type
        if update_type.blank?
          raise_command_error(422, "update_type is required", fields: {
            update_type: ["is invalid"],
          })
        elsif !valid_update_types.include?(update_type)
          raise_command_error(422, "An update_type of '#{update_type}' is invalid", fields: {
            update_type: ["must be one of #{valid_update_types.inspect}"],
          })
        end
      end

      def delete_change_notes
        ChangeNote.where(edition: edition).delete_all
      end

      def document
        @document ||= Document.find_or_create_locked(
          content_id: payload[:content_id],
          locale: payload.fetch(:locale, Edition::DEFAULT_LOCALE),
        )
      end

      def content_id
        document.content_id
      end

      def locale
        document.locale
      end

      def previous_version_number
        payload[:previous_version].to_i if payload[:previous_version]
      end

      def valid_update_types
        %w(major minor republish links)
      end

      def already_published?
        document.editions.exists?(state: "published")
      end

      def clear_published_items_of_same_locale_and_base_path
        SubstitutionHelper.clear!(
          new_item_document_type: edition.document_type,
          new_item_content_id: document.content_id,
          state: %w[published unpublished],
          locale: document.locale,
          base_path: edition.base_path,
          downstream: downstream,
          callbacks: callbacks,
          nested: true,
        )
      end

      def set_public_updated_at
        return if edition.public_updated_at.present?

        if update_type == "major"
          edition.update_attributes!(public_updated_at: Time.zone.now)
        elsif update_type == "minor"
          edition.update_attributes!(public_updated_at: previous_item.public_updated_at)
        end
      end

      def set_first_published_at
        return if edition.first_published_at.present?
        edition.update_attributes!(first_published_at: Time.zone.now)
      end

      def publish_redirect(previous_base_path, locale)
        draft_redirect = Edition.with_document.find_by(
          state: "draft",
          "documents.locale": locale,
          base_path: previous_base_path,
          schema_name: "redirect",
        )

        self.class.call(
          {
            content_id: draft_redirect.document.content_id,
            locale: draft_redirect.document.locale,
            update_type: "major",
          },
          downstream: downstream,
          callbacks: callbacks,
          nested: true,
        ) if draft_redirect
      end

      def update_dependencies?
        EditionDiff.new(edition).field_diff.present?
      end

      def send_downstream_live
        queue = update_type == 'republish' ? DownstreamLiveWorker::LOW_QUEUE : DownstreamLiveWorker::HIGH_QUEUE
        DownstreamLiveWorker.perform_async_in_queue(
          queue,
          live_worker_params
        )
      end

      def send_downstream_draft
        queue = update_type == 'republish' ? DownstreamDraftWorker::LOW_QUEUE : DownstreamDraftWorker::HIGH_QUEUE
        DownstreamDraftWorker.perform_async_in_queue(
          queue,
          worker_params
        )
      end

      def live_worker_params
        {
          message_queue_update_type: update_type,
          update_dependencies: update_dependencies?,
          orphaned_content_ids: orphaned_content_ids,
        }.merge(worker_params)
      end

      def worker_params
        {
          content_id: content_id,
          locale: locale,
          payload_version: event.id,
        }
      end

      def html_publication?
        edition.document_type == 'html_publication'
      end

      def render_pdf
        html = fetch_rendered_html_for_edition
        pdf_kit = PDFKit.new(html, viewport_size: '1280x1024')

        pdf_io = StringIO.new
        pdf_io.write(pdf_kit.to_pdf)
        pdf_io.rewind
        pdf_string = pdf_io.read

        filename = edition.title.parameterize

        file = Tempfile.new([filename, '.pdf'], encoding: 'utf-8')
        file.write(pdf_string)

        asset_manager = GdsApi::AssetManager.new(
          Plek.find('asset-manager'),
          bearer_token: ENV['ASSET_MANAGER_BEARER_TOKEN'] || '12345678'
        )

        # TODO: Check the HTML attachment if a PDF exists already, and do an update instead using update_asset
        # NB: Something about gds-api-adapters and/or asset-manager doesn't like Tempfiles, but for some
        # reason if we hand it a File object instead, everything works just fine
        asset_result = asset_manager.create_asset(file: File.open(file.path))
        file.close!

        asset_url = asset_result['file_url']

        # We'll probably want to do this in a worker (along with the rest of this rendering), since the
        # URL we receive from Asset Manager will not necessarily return the PDF immediately
        # NB: We should probably also update the links on the parent Edition, so that we can link to the PDF
        # from the Edition page
        edition.update_attributes!(details: edition[:details].merge(pdf_asset_url: asset_url))
      end

      def fetch_rendered_html_for_edition
        # TODO: We'll probably want to check that we're fetching the latest version of the HTML, or - better yet -
        # fetch it from the previewing API
        url = Plek.find('government-frontend') + edition[:base_path]
        open(url).read
      end
    end
  end
end
