require "rails_helper"

RSpec.describe Commands::V2::PutContent do
  describe "call" do
    before do
      stub_request(:delete, %r{.*content-store.*/content/.*})
      stub_request(:put, %r{.*content-store.*/content/.*})
      allow_any_instance_of(Commands::V2::PutContentValidator).to receive(:validate).and_return(true)
    end

    let(:content_id) { SecureRandom.uuid }
    let(:base_path) { "/vat-rates" }
    let(:locale) { "en" }
    let(:change_note) { { note: "Info", public_timestamp: Time.now.utc.to_s } }

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
      }
    end

    it "sends to the downstream draft worker" do
      expect(DownstreamDraftWorker).to receive(:perform_async_in_queue)
        .with(
          "downstream_high",
          a_hash_including(:content_id, :locale, :payload_version, update_dependencies: true),
        )

      described_class.call(payload)
    end

    it "does not send to the downstream publish worker" do
      expect(DownstreamLiveWorker).not_to receive(:perform_async_in_queue)
      described_class.call(payload)
    end

    context "when the 'downstream' parameter is false" do
      it "does not send to the downstream draft worker" do
        expect(DownstreamDraftWorker).not_to receive(:perform_async_in_queue)

        described_class.call(payload, downstream: false)
      end
    end

    context "when the 'bulk_publishing' flag is set" do
      it "enqueues in the correct queue" do
        expect(DownstreamDraftWorker).to receive(:perform_async_in_queue)
          .with(
            "downstream_low",
            anything
          )

        described_class.call(payload.merge(bulk_publishing: true))
      end
    end

    context "when the base path has been reserved by another publishing app" do
      before do
        FactoryGirl.create(:path_reservation,
          base_path: base_path,
          publishing_app: "something-else"
        )
      end

      it "raises an error" do
        expect {
          described_class.call(payload)
        }.to raise_error(CommandError, /is already reserved/i)
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

      context "and the base path has changed" do
        before do
          payload.merge!(
            base_path: "/moved",
            routes: [{ path: "/moved", type: "exact" }],
          )
        end

        it "sends a create request to the draft content store for the redirect" do
          expect(DownstreamDraftWorker).to receive(:perform_async_in_queue).twice

          described_class.call(payload)
        end
      end

      describe "race conditions", skip_cleaning: true do
        after do
          DatabaseCleaner.clean_with :truncation
        end

        it "copes with race conditions" do
          described_class.call(payload)
          Commands::V2::Publish.call(content_id: content_id, update_type: "minor")

          thread1 = Thread.new { described_class.call(payload) }
          thread2 = Thread.new { described_class.call(payload) }
          thread1.join
          thread2.join

          expect(Edition.all.pluck(:state)).to match_array(%w(superseded published draft))
        end
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

      context "when the base path has changed" do
        before do
          previously_drafted_item.update_attributes!(
            routes: [{ path: "/old-path", type: "exact" }, { path: "/old-path.atom", type: "exact" }],
            base_path: "/old-path",
          )
        end

        it "sends a create request to the draft content store for the redirect" do
          expect(DownstreamDraftWorker).to receive(:perform_async_in_queue).twice

          described_class.call(payload)
        end
      end

      context "with a 'previous_version' which does not match the current lock_version of the draft item" do
        before do
          previously_drafted_item.document.update!(stale_lock_version: 2)
          payload.merge!(previous_version: 1)
        end

        it "raises an error" do
          expect {
            described_class.call(payload)
          }.to raise_error(CommandError, /Conflict/)
        end
      end

      context "when the previous draft has an access limit" do
        let!(:access_limit) do
          FactoryGirl.create(:access_limit, edition: previously_drafted_item, users: ["old-user"])
        end

        context "when the params includes an access limit" do
          let(:auth_bypass_id) { SecureRandom.uuid }
          before do
            payload.merge!(
              access_limited: {
                users: ["new-user"],
                auth_bypass_ids: [auth_bypass_id],
              }
            )
          end

          it "updates the existing access limit" do
            described_class.call(payload)
            access_limit.reload

            expect(access_limit.users).to eq(["new-user"])
            expect(access_limit.auth_bypass_ids).to eq([auth_bypass_id])
          end
        end

        context "when the params does not include an access limit" do
          it "deletes the existing access limit" do
            expect {
              described_class.call(payload)
            }.to change(AccessLimit, :count).by(-1)
          end
        end
      end

      context "when the previously drafted item does not have an access limit" do
        context "when the params includes an access limit" do
          let(:auth_bypass_id) { SecureRandom.uuid }
          before do
            payload.merge!(
              access_limited: {
                users: ["new-user"],
                auth_bypass_ids: [auth_bypass_id],
              }
            )
          end

          it "creates a new access limit" do
            expect {
              described_class.call(payload)
            }.to change(AccessLimit, :count).by(1)

            access_limit = AccessLimit.find_by!(edition: previously_drafted_item)
            expect(access_limit.users).to eq(["new-user"])
            expect(access_limit.auth_bypass_ids).to eq([auth_bypass_id])
          end
        end
      end
    end

    context "when the params includes an access limit" do
      before do
        payload.merge!(access_limited: { users: ["new-user"] })
      end

      it "creates a new access limit" do
        expect {
          described_class.call(payload)
        }.to change(AccessLimit, :count).by(1)

        access_limit = AccessLimit.last
        expect(access_limit.users).to eq(["new-user"])
        expect(access_limit.edition).to eq(Edition.last)
      end
    end

    context "when the 'links' parameter is provided" do
      before do
        payload.merge!(links: { users: [link] })
      end

      context "invalid UUID" do
        let!(:link) { "not a UUID" }

        it "should raise a validation error" do
          expect {
            described_class.call(payload)
          }.to raise_error(CommandError, /UUID/)
        end
      end

      context "valid UUID" do
        let(:document) { FactoryGirl.create(:document) }
        let!(:link) { document.content_id }

        it "should create a link" do
          expect {
            described_class.call(payload)
          }.to change(Link, :count).by(1)

          expect(Link.find_by(target_content_id: document.content_id)).to be
        end
      end

      context "existing links" do
        let(:document) { FactoryGirl.create(:document, content_id: content_id) }
        let(:content_id) { SecureRandom.uuid }
        let(:link) { SecureRandom.uuid }

        before do
          edition.links.create!(target_content_id: document.content_id, link_type: "random")
        end

        context "draft edition" do
          let(:edition) { FactoryGirl.create(:draft_edition, document: document, base_path: base_path) }

          it "passes the old link to dependency resolution" do
            expect(DownstreamDraftWorker).to receive(:perform_async_in_queue).with(
              "downstream_high",
              a_hash_including(orphaned_content_ids: [content_id])
            )
            described_class.call(payload)
          end
        end

        context "published edition" do
          let(:edition) { FactoryGirl.create(:live_edition, document: document, base_path: base_path) }

          it "passes the old link to dependency resolution" do
            expect(DownstreamDraftWorker).to receive(:perform_async_in_queue).with(
              "downstream_high",
              a_hash_including(orphaned_content_ids: [content_id])
            )
            described_class.call(payload)
          end
        end
      end
    end

    context 'without a publishing_app' do
      before do
        payload.delete(:publishing_app)
        allow_any_instance_of(Commands::V2::PutContentValidator)
          .to receive(:validate)
          .and_raise(CommandError.new(code: 422, message: /publishing_app is required/))
      end

      it "raises an error" do
        expect {
          described_class.call(payload)
        }.to raise_error(CommandError, /publishing_app is required/)
      end
    end

    it_behaves_like TransactionalCommand

    context "when the draft does not exist" do
      context "with a provided last_edited_at" do
        it "stores the provided timestamp" do
          last_edited_at = 1.year.ago

          described_class.call(payload.merge(last_edited_at: last_edited_at))

          edition = Edition.last

          expect(edition.last_edited_at.iso8601).to eq(last_edited_at.iso8601)
        end
      end

      it "stores last_edited_at as the current time" do
        Timecop.freeze do
          described_class.call(payload)

          edition = Edition.last

          expect(edition.last_edited_at.iso8601).to eq(Time.zone.now.iso8601)
        end
      end
    end

    context "when the draft does exist" do
      let!(:edition) do
        FactoryGirl.create(:draft_edition,
          document: FactoryGirl.create(:document, content_id: content_id)
        )
      end

      context "with a provided last_edited_at" do
        %w(minor major republish).each do |update_type|
          context "with update_type of #{update_type}" do
            it "stores the provided timestamp" do
              last_edited_at = 1.year.ago

              described_class.call(
                payload.merge(
                  update_type: update_type,
                  last_edited_at: last_edited_at,
                )
              )

              edition.reload

              expect(edition.last_edited_at.iso8601).to eq(last_edited_at.iso8601)
            end
          end
        end
      end

      it "stores last_edited_at as the current time" do
        Timecop.freeze do
          described_class.call(payload)

          edition.reload

          expect(edition.last_edited_at.iso8601).to eq(Time.zone.now.iso8601)
        end
      end

      context "when other update type" do
        it "doesn't change last_edited_at" do
          old_last_edited_at = edition.last_edited_at

          described_class.call(payload.merge(update_type: "republish"))

          edition.reload

          expect(edition.last_edited_at).to eq(old_last_edited_at)
        end
      end
    end

    context "with a pathless edition payload" do
      let(:payload) { pathless_payload }

      it "sends to the downstream draft worker" do
        expect(DownstreamDraftWorker).to receive(:perform_async_in_queue)
        described_class.call(payload)
      end
    end

    context "where a base_path is optional and supplied" do
      let(:payload) do
        pathless_payload.merge(
          base_path: base_path,
          routes: [{ path: base_path, type: "exact" }],
        )
      end

      it "sends to the content-store" do
        expect(DownstreamDraftWorker).to receive(:perform_async_in_queue)
        described_class.call(payload)
      end
    end

    context "schema validation fails" do
      let(:errors) do
        [{ schema: "a", fragment: "b", message: "c", failed_attribute: "d" }]
      end
      before do
        allow_any_instance_of(Commands::V2::PutContentValidator)
          .to receive(:validate)
          .and_raise(CommandError.new(code: 422, message: /publishing_app is required/, error_details: errors))
      end

      it "raises command error and exits" do
        expect(PathReservation).not_to receive(:reserve_base_path!)
        expect { described_class.call(payload) }.to raise_error { |error|
          expect(error).to be_a(CommandError)
          expect(error.code).to eq 422
          expect(error.error_details).to eq errors
        }
      end
    end

    context "schema validation passes" do
      it "returns success" do
        expect(PathReservation).to receive(:reserve_base_path!)
        expect { described_class.call(payload) }.not_to raise_error
      end
    end

    context "field doesn't change between drafts" do
      it "doesn't update the dependencies" do
        expect(DownstreamDraftWorker).to receive(:perform_async_in_queue)
          .with(anything, a_hash_including(update_dependencies: true))
        expect(DownstreamDraftWorker).to receive(:perform_async_in_queue)
          .with(anything, a_hash_including(update_dependencies: false))
        described_class.call(payload)
        described_class.call(payload)
      end
    end
  end
end
