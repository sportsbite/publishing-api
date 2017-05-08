module Presenters
  module Queries
    class AvailableTranslations
      def initialize(content_id, with_drafts: false)
        @content_id = content_id
        @with_drafts = with_drafts
      end

      def translations
        return {} unless expanded_translations.present?
        { available_translations: expanded_translations }
      end

    private

      attr_reader :content_id, :with_drafts, :expanded_translations

      def grouped_translations
        pluck_and_sort_editions(edition_scope)
      end

      def expand_translation(id)
        web_item(id).select do |field|
          LinkExpansion::Rules
            .expansion_fields(:available_translations)
            .include?(field)
        end
      end

      def web_item(id)
        Edition.find_by(id: id).to_h
      end

      def expanded_translations
        @expanded_translations ||= grouped_translations.map do |_, (id)|
          expand_translation(id)
        end
      end

      def state_fallback_order
        return %i[draft published unpublished] if with_drafts
        %i[published unpublished]
      end

      def edition_scope
        scope = Edition
          .with_document
          .with_unpublishing
          .where(
            documents: { content_id: content_id },
            state: state_fallback_order,
          )

        # filter out unpublishings which aren't withdrawals (i.e. gone, redirect, etc)
        scope
          .where("
            editions.state != 'unpublished' OR unpublishings.type = 'withdrawal'
          ")
      end

      def pluck_and_sort_editions(scope)
        scope.pluck(:id, :locale, :state)
          .sort_by { |(_, _, state)| state_fallback_order.index(state.to_sym) }
          .group_by { |(_, locale)| locale }
          .each_with_object({}) { |(key, value), hash| hash[key] = value.first }
      end
    end
  end
end
