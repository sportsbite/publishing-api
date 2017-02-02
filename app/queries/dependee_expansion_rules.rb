module Queries
  module DependeeExpansionRules
    extend ExpansionRules
    extend self

    def recursive_link_types
      [
        [:parent],
        [:parent_taxons],
        [:taxons, :parent_taxons],
        [:ordered_related_items, :mainstream_browse_pages, :parent],
      ]
    end

    def name_for(link_type)
      link_type
    end

    def next_level_link_types(link_path)
      return if link_path.empty?
      next_level_recursive_types(link_path)
    end

  private

    def custom_fields(link_type)
      {
        redirect: [],
        gone: [],
        topical_event: default_fields + [:details],
        placeholder_topical_event: default_fields + [:details],
        organisation: default_fields + [:details],
        placeholder_organisation: default_fields + [:details],
        taxon: default_fields + [:details],
        need: default_fields + [:details],
      }[link_type]
    end
  end
end
