#
# This is the core class of Link Expansion which is a complicated concept
# in the Publishing API
#
# The concept is documented in /doc/link-expansion.md
#
class LinkExpansion
  def self.by_edition(edition, with_drafts: false)
    self.new(edition: edition, with_drafts: with_drafts)
  end

  def self.by_content_id(content_id, locale: Edition::DEFAULT_LOCALE, with_drafts: false)
    self.new(content_id: content_id, locale: locale, with_drafts: with_drafts)
  end

  def initialize(options)
    ActiveRecord::Base.logger = nil
    # Benchmark.measure { Presenters::Queries::ExpandedLinkSet.by_content_id("91b8ef20-74e7-4552-880c-50e6d73c2ff9").links }
    @options = options
    @with_drafts = options.fetch(:with_drafts)
    @start_time = Time.now
    @timings = { }
  end

  def links_with_content
    populated_links = populate_links(link_graph.links)
    puts "Method timings:"
    puts @timings
    populated_links
  end

  def link_graph
    @link_graph ||= LinkGraph.new(
      root_content_id: content_id,
      root_locale: locale,
      with_drafts: with_drafts,
      link_reference: LinkReference.new
    )
  end

private

  attr_reader :options, :with_drafts

  def edition
    @edition ||= options[:edition]
  end

  def content_id
    edition ? edition.content_id : options.fetch(:content_id)
  end

  def locale
    edition ? edition.locale : options.fetch(:locale)
  end

  def content_cache
    @content_cache ||= ContentCache.new(
      locale: locale,
      preload_editions: edition ? [edition] : [],
      preload_content_ids: preload_content_ids,
      with_drafts: with_drafts,
    )
  end

  def preload_content_ids
    timing = Time.now
    content_ids = (link_graph.links_content_ids + [content_id]).uniq
    add_timing("link_graph.links_content_ids", timing)
    content_ids
  end

  def populate_links(links)
    populated = links.each_with_object({}) do |link_node, memo|
      content = link_content(link_node)
      (memo[link_node.link_type] ||= []) << content if content
    end
    populated
  end

  def link_content(node)
    timing = Time.now
    edition = content_cache.find(node.content_id, true)
    add_timing("content_cache", timing)
    return if !edition || !should_link?(node.link_type, edition)
    ef_timing = Time.now
    expanded_fields = rules.expand_fields(edition, node.link_type)
    add_timing("expand_fields", ef_timing)
    expanded_fields.tap do |expanded|
      timing = Time.now
      links = populate_links(node.links)
      add_timing("populate_links", timing)
      timing = Time.now
      auto_reverse = auto_reverse_link(node)
      add_timing("auto_reverse_link", timing)
      expanded.merge!(links: (auto_reverse || {}).merge(links))
    end
    expanded_fields
  end

  def auto_reverse_link(node)
    if node.link_types_path.length != 1 || !rules.is_reverse_link_type?(node.link_types_path.first)
      return {}
    end
    edition = content_cache.find(content_id)
    return if !edition || !should_link?(node.link_type, edition)
    un_reverse_link_type = rules.un_reverse_link_type(node.link_types_path.first)
    { un_reverse_link_type => [rules.expand_fields(edition, un_reverse_link_type).merge(links: {})] }
  end

  def should_link?(link_type, edition)
    # Only specific link types can be withdrawn
    # FIXME: We're leaking publishing app domain knowledge into the API here.
    # The agreed approach will be to allow any withdrawn links to appear but
    # this requires we assess impact on the rendering applications first.
    %i(children parent related_statistical_data_sets).include?(link_type) ||
      edition.state != "unpublished"
  end

  def rules
    Rules
  end

  def add_timing(key, start_time = @start_time)
    @timings[key] = 0.0 unless @timings.has_key?(key)
    @timings[key] += (Time.now - start_time)
  end
end
