require "rails_helper"

RSpec.describe "Updating content" do
  subject(:put_content) { Commands::V2::PutContent }
  let(:locale) { "en" }
  let(:change_note) { { note: "Info", public_timestamp: Time.now.utc.to_s } }
  let(:base_path) { "/vat-rates" }
  let(:payload) do
    {
      content_id: content_id,
      base_path: base_path,
      update_type: "major",
      title: "Some Title",
      publishing_app: "publisher",
      rendering_app: "government-frontend",
      document_type: "answer",
      schema_name: "answer",
      locale: locale,
      routes: [{ path: base_path, type: "exact" }],
      redirects: [],
      phase: "beta",
      change_note: change_note
    }
  end

  let(:pathless_payload) do
    {
      content_id: content_id,
      title: "Some Title",
      publishing_app: "publisher",
      rendering_app: "frontend",
      document_type: "contact",
      details: { title: "Contact Title" },
      schema_name: "contact",
      locale: locale,
      phase: "beta",
    }
  end

  before do
    stub_request(:put, %r{.*content-store.*/content/.*})
  end

  it "creates an action" do
    expect(Action.count).to be 0
    subject.call(payload)
    expect(Action.count).to be 1
    expect(Action.first.attributes).to match a_hash_including(
      "content_id" => content_id,
      "locale" => locale,
      "action" => "PutContent",
    )
  end

  context "when there are no previous path reservations" do
    it "creates a path reservation" do
      expect {
        subject.call(payload)
      }.to change(PathReservation, :count).by(1)

      reservation = PathReservation.last
      expect(reservation.base_path).to eq("/vat-rates")
      expect(reservation.publishing_app).to eq("publisher")
    end
  end

  context "when creating a draft for a previously published edition" do
    let(:first_published_at) { 1.year.ago }

    let(:document) do
      FactoryGirl.create(
        :document,
        content_id: content_id,
        stale_lock_version: 5,
      )
    end

    let!(:edition) do
      FactoryGirl.create(:live_edition,
        document: document,
        user_facing_version: 5,
        first_published_at: first_published_at,
        base_path: base_path,
      )
    end

    let!(:link) do
      edition.links.create(link_type: "test",
                           target_content_id: document.content_id)
    end

    it "creates the draft's user-facing version using the live's user-facing version as a starting point" do
      put_content.call(payload)

      edition = Edition.last

      expect(edition).to be_present
      expect(edition.document.content_id).to eq(content_id)
      expect(edition.state).to eq("draft")
      expect(edition.user_facing_version).to eq(6)
    end

    it "copies over the first_published_at timestamp" do
      subject.call(payload)

      edition = Edition.last
      expect(edition).to be_present
      expect(edition.document.content_id).to eq(content_id)

      expect(edition.first_published_at.iso8601).to eq(first_published_at.iso8601)
    end

    context "and the base path has changed" do
      before do
        payload.merge!(
          base_path: "/moved",
          routes: [{ path: "/moved", type: "exact" }],
        )
      end

      it "sets the correct base path on the location" do
        subject.call(payload)

        expect(Edition.where(base_path: "/moved", state: "draft")).to exist
      end

      it "creates a redirect" do
        subject.call(payload)

        redirect = Edition.find_by(
          base_path: base_path,
          state: "draft",
        )

        expect(redirect).to be_present
        expect(redirect.schema_name).to eq("redirect")
        expect(redirect.publishing_app).to eq("publisher")

        expect(redirect.redirects).to eq([{
          path: base_path,
          type: "exact",
          destination: "/moved",
        }])
      end

      context "when the locale differs from the existing draft edition" do
        before do
          payload.merge!(locale: "fr", title: "French Title")
        end

        it "creates a separate draft edition in the given locale" do
          subject.call(payload)
          expect(Edition.count).to eq(2)

          edition = Edition.last
          expect(edition.title).to eq("French Title")
          expect(edition.document.locale).to eq("fr")
        end
      end
    end
  end

  context "when creating a draft for a previously unpublished edition" do
    before do
      FactoryGirl.create(:unpublished_edition,
        document: FactoryGirl.create(:document, content_id: content_id, stale_lock_version: 2),
        user_facing_version: 5,
        base_path: base_path,
      )
    end

    it "creates the draft's lock version using the unpublished lock version as a starting point" do
      subject.call(payload)

      edition = Edition.last

      expect(edition).to be_present
      expect(edition.document.content_id).to eq(content_id)
      expect(edition.state).to eq("draft")
      expect(edition.document.stale_lock_version).to eq(3)
    end

    it "creates the draft's user-facing version using the unpublished user-facing version as a starting point" do
      subject.call(payload)

      edition = Edition.last

      expect(edition).to be_present
      expect(edition.document.content_id).to eq(content_id)
      expect(edition.state).to eq("draft")
      expect(edition.user_facing_version).to eq(6)
    end

    it "allows the setting of first_published_at" do
      explicit_first_published = DateTime.new(2016, 05, 23, 1, 1, 1).rfc3339
      payload[:first_published_at] = explicit_first_published

      subject.call(payload)

      edition = Edition.last

      expect(edition).to be_present
      expect(edition.document.content_id).to eq(content_id)
      expect(edition.first_published_at).to eq(explicit_first_published)
    end
  end

  context "when the payload is for a brand new edition" do
    it "creates an edition" do
      subject.call(payload)
      edition = Edition.last

      expect(edition).to be_present
      expect(edition.document.content_id).to eq(content_id)
      expect(edition.title).to eq("Some Title")
    end

    it "sets a draft state for the edition" do
      subject.call(payload)
      edition = Edition.last

      expect(edition.state).to eq("draft")
    end

    it "sets a user-facing version of 1 for the edition" do
      subject.call(payload)
      edition = Edition.last

      expect(edition.user_facing_version).to eq(1)
    end

    it "creates a lock version for the edition" do
      subject.call(payload)
      edition = Edition.last

      expect(edition.document.stale_lock_version).to eq(1)
    end

    shared_examples "creates a change note" do
      it "creates a change note" do
        expect { subject.call(payload) }.
          to change { ChangeNote.count }.by(1)
      end
    end

    context "and the change node is in the payload" do
      include_examples "creates a change note"
    end

    context "and the change history is in the details hash" do
      before do
        payload.delete(:change_note)
        payload[:details] = { change_history: [change_note] }
      end

      include_examples "creates a change note"
    end

    context "and the change note is in the details hash" do
      before do
        payload.delete(:change_note)
        payload[:details] = { change_note: change_note[:note] }
      end

      include_examples "creates a change note"
    end
  end

  context "when the payload is for an already drafted edition" do
    let(:document) do
      FactoryGirl.create(:document, content_id: content_id, stale_lock_version: 1)
    end
    let!(:previously_drafted_item) do
      FactoryGirl.create(:draft_edition,
        document: document,
        base_path: base_path,
        title: "Old Title",
        publishing_app: "publisher",
      )
    end

    it "updates the edition" do
      subject.call(payload)
      previously_drafted_item.reload

      expect(previously_drafted_item.title).to eq("Some Title")
    end

    it "keeps the content_store as draft" do
      subject.call(payload)
      previously_drafted_item.reload

      expect(previously_drafted_item.content_store).to eq("draft")
    end

    it "allows the setting of first_published_at" do
      explicit_first_published = DateTime.new(2016, 05, 23, 1, 1, 1).rfc3339
      payload[:first_published_at] = explicit_first_published

      subject.call(payload)

      expect(previously_drafted_item.reload.first_published_at)
        .to eq(explicit_first_published)
    end

    it "keeps the first_published_at timestamp if not set in payload" do
      first_published_at = 1.year.ago
      previously_drafted_item.update_attributes(first_published_at: first_published_at)

      subject.call(payload)
      previously_drafted_item.reload

      expect(previously_drafted_item.first_published_at).to be_present
      expect(previously_drafted_item.first_published_at.iso8601).to eq(first_published_at.iso8601)
    end

    it "does not increment the user-facing version for the edition" do
      subject.call(payload)
      previously_drafted_item.reload

      expect(previously_drafted_item.user_facing_version).to eq(1)
    end

    it "increments the lock version for the document" do
      subject.call(payload)

      expect(document.reload.stale_lock_version).to eq(2)
    end

    context "when the base path has changed" do
      before do
        previously_drafted_item.update_attributes!(
          routes: [{ path: "/old-path", type: "exact" }, { path: "/old-path.atom", type: "exact" }],
          base_path: "/old-path",
        )
      end

      it "updates the location's base path" do
        subject.call(payload)
        previously_drafted_item.reload

        expect(previously_drafted_item.base_path).to eq("/vat-rates")
      end

      it "creates a redirect" do
        subject.call(payload)

        redirect = Edition.find_by(
          base_path: "/old-path",
          state: "draft",
        )

        expect(redirect).to be_present
        expect(redirect.schema_name).to eq("redirect")
        expect(redirect.publishing_app).to eq("publisher")

        expect(redirect.redirects).to eq([
          {
            path: "/old-path",
            type: "exact",
            destination: base_path
          }, {
            path: "/old-path.atom",
            type: "exact",
            destination: "#{base_path}.atom"
          }
        ])
      end

      context "when the locale differs from the existing draft edition" do
        before do
          payload.merge!(locale: "fr", title: "French Title")
        end

        it "creates a separate draft edition in the given locale" do
          subject.call(payload)
          expect(Edition.count).to eq(2)

          edition = Edition.last
          expect(edition.title).to eq("French Title")

          expect(edition.document.locale).to eq("fr")
        end
      end

      context "when there is a draft at the new base path" do
        let!(:substitute_item) do
          FactoryGirl.create(:draft_edition,
            base_path: base_path,
            title: "Substitute Content",
            publishing_app: "publisher",
            document_type: "coming_soon",
          )
        end

        it "deletes the substitute item" do
          subject.call(payload)
          expect(Edition.exists?(id: substitute_item.id)).to eq(false)
        end

        context "conflicting version" do
          before do
            previously_drafted_item.document.update!(stale_lock_version: 2)
            payload.merge!(previous_version: 1)
          end

          it "doesn't delete the substitute item" do
            expect {
              subject.call(payload)
            }.to raise_error(CommandError, /Conflict/)
            expect(Edition.exists?(id: substitute_item.id)).to eq(true)
          end
        end
      end
    end

    context "when some of the attributes are not provided in the payload" do
      before do
        payload.delete(:redirects)
        payload.delete(:phase)
        payload.delete(:locale)
      end

      it "resets those attributes to their defaults from the database" do
        subject.call(payload)
        edition = Edition.last

        expect(edition.redirects).to eq([])
        expect(edition.phase).to eq("live")
        expect(edition.document.locale).to eq("en")
      end
    end
  end

  context "without a base_path" do
    before do
      payload.delete(:base_path)
    end

    context "when schema requires a base_path" do
      it "raises an error" do
        expect {
          subject.call(payload)
        }.to raise_error(CommandError, /Base path is not a valid absolute URL path/)
      end
    end

    context "when schema does not require a base_path" do
      before do
        payload.merge!(schema_name: 'government', document_type: 'government').delete(:format)
      end

      it "does not raise an error" do
        expect {
          subject.call(payload)
        }.not_to raise_error
      end

      it "does not try to reserve a path" do
        expect {
          subject.call(payload)
        }.not_to change(PathReservation, :count)
      end
    end
  end

  context "with a pathless edition payload" do
    let(:payload) { pathless_payload }

    it "saves the content as draft" do
      expect {
        subject.call(payload)
      }.to change(Edition, :count).by(1)
    end

    context "for an existing draft edition" do
      let!(:draft_edition) do
        FactoryGirl.create(:draft_edition,
          document: FactoryGirl.create(:document, content_id: content_id),
          title: "Old Title"
        )
      end

      it "updates the draft" do
        subject.call(payload)
        expect(draft_edition.reload.title).to eq("Some Title")
      end
    end

    context "for an existing live edition" do
      let!(:live_edition) do
        FactoryGirl.create(:live_edition,
          document: FactoryGirl.create(:document, content_id: content_id),
          title: "Old Title"
        )
      end

      it "creates a new draft" do
        expect {
          subject.call(payload)
        }.to change(Edition, :count).by(1)
      end
    end
  end

  context "where a base_path is optional and supplied" do
    let(:payload) do
      pathless_payload.merge(
        base_path: base_path,
        routes: [{ path: base_path, type: "exact" }],
      )
    end

    # This covers a specific edge case where the edition uniqueness validator
    # matched anything else with the same state, locale and version because it
    # was previously ignoring the base path, now it should return without
    # attempting to validate for pathless formats.
    context "with other similar pathless items" do
      before do
        FactoryGirl.create(:draft_edition,
          base_path: nil,
          schema_name: "contact",
          document_type: "contact",
          user_facing_version: 3,
        )
      end

      it "doesn't conflict" do
        expect {
          subject.call(payload)
        }.not_to raise_error
      end
    end

    context "when there's a conflicting edition" do
      before do
        FactoryGirl.create(:draft_edition,
          base_path: base_path,
          schema_name: "contact",
          document_type: "contact",
          user_facing_version: 3,
        )
      end

      it "conflicts" do
        expect {
          subject.call(payload)
        }.to raise_error(CommandError, /base path=\/vat-rates conflicts/)
      end
    end
  end
end
