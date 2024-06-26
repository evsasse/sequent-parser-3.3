# frozen_string_literal: true

require 'spec_helper'
require 'sequent/support'
require 'postgresql_cursor'

describe Sequent::Core::EventStore do
  class MyEvent < Sequent::Core::Event
    attrs data: String
  end

  class MyAggregate < Sequent::Core::AggregateRoot
  end

  let(:event_store) { Sequent.configuration.event_store }
  let(:aggregate_id) { Sequent.new_uuid }

  context '.configure' do
    it 'can be configured using a ActiveRecord class' do
      Sequent.configuration.stream_record_class = :foo
      expect(Sequent.configuration.stream_record_class).to eq :foo
    end

    it 'can be configured with event_handlers' do
      event_handler_class = Class.new
      Sequent.configure do |config|
        config.event_handlers = [event_handler_class]
      end
      expect(Sequent.configuration.event_handlers).to eq [event_handler_class]
    end

    it 'configuring a second time will reset the configuration' do
      foo = Class.new
      bar = Class.new
      Sequent.configure do |config|
        config.event_handlers = [foo]
      end
      expect(Sequent.configuration.event_handlers).to eq [foo]
      Sequent.configure do |config|
        config.event_handlers << bar
      end
      expect(Sequent.configuration.event_handlers).to eq [bar]
    end
  end

  context 'snapshotting' do
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
            ),
            [
              MyEvent.new(
                aggregate_id: aggregate_id,
                sequence_number: 1,
                created_at: Time.parse('2024-02-29T01:10:12Z'),
                data: "with ' unsafe SQL characters;\n",
              ),
            ],
          ],
        ],
      )
    end

    let(:aggregate) do
      stream, events = event_store.load_events(aggregate_id)
      Sequent::Core::AggregateRoot.load_from_history(stream, events)
    end

    let(:snapshot) do
      snapshot = aggregate.take_snapshot
      snapshot.created_at = Time.parse('2024-02-28T04:12:33Z')
      snapshot
    end

    it 'can mark aggregates for snapshotting when storing new events' do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
              snapshot_outdated_at: Time.now,
            ),
            [
              MyEvent.new(
                aggregate_id: aggregate_id,
                sequence_number: 2,
                created_at: Time.parse('2024-02-30T01:10:12Z'),
                data: "another event\n",
              ),
            ],
          ],
        ],
      )
      expect(event_store.aggregates_that_need_snapshots(nil)).to include(aggregate_id)

      event_store.store_snapshots([snapshot])
      expect(event_store.aggregates_that_need_snapshots(nil)).to be_empty
    end

    it 'can no longer find the aggregates that are cleared for snapshotting' do
      event_store.store_snapshots([snapshot])

      event_store.clear_aggregate_for_snapshotting(aggregate_id)
      expect(event_store.aggregates_that_need_snapshots(nil)).to be_empty
      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(nil)

      event_store.mark_aggregate_for_snapshotting(aggregate_id)
      expect(event_store.aggregates_that_need_snapshots(nil)).to include(aggregate_id)
    end

    it 'can no longer find aggregates what are clear for snapshotting based on latest event timestamp' do
      event_store.store_snapshots([snapshot])

      event_store.clear_aggregates_for_snapshotting_with_last_event_before(Time.now)
      expect(event_store.aggregates_that_need_snapshots(nil)).to be_empty
      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(nil)
    end

    it 'can store and delete snapshots' do
      event_store.store_snapshots([snapshot])

      expect(event_store.aggregates_that_need_snapshots(nil)).to be_empty
      expect(event_store.aggregates_that_need_snapshots_ordered_by_priority(nil)).to be_empty
      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(snapshot)

      event_store.delete_snapshots_before(aggregate_id, snapshot.sequence_number + 1)

      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(nil)
      expect(event_store.aggregates_that_need_snapshots(nil)).to include(aggregate_id)
      expect(event_store.aggregates_that_need_snapshots_ordered_by_priority(nil)).to include(aggregate_id)
    end

    it 'can delete all snapshots' do
      event_store.store_snapshots([snapshot])

      expect(event_store.aggregates_that_need_snapshots(nil)).to be_empty
      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(snapshot)
      expect(event_store.aggregates_that_need_snapshots_ordered_by_priority(nil)).to be_empty

      event_store.delete_all_snapshots

      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(nil)
      expect(event_store.aggregates_that_need_snapshots(nil)).to include(aggregate_id)
      expect(event_store.aggregates_that_need_snapshots_ordered_by_priority(nil)).to include(aggregate_id)
    end
  end

  describe '#commit_events' do
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
              snapshot_outdated_at: Time.now,
            ),
            [
              MyEvent.new(
                aggregate_id: aggregate_id,
                sequence_number: 1,
                created_at: Time.parse('2024-02-29T01:10:12Z'),
                data: "with ' unsafe SQL characters;\n",
              ),
            ],
          ],
        ],
      )
    end

    it 'can store events' do
      stream, events = event_store.load_events aggregate_id

      expect(stream.aggregate_type).to eq('MyAggregate')
      expect(stream.aggregate_id).to eq(aggregate_id)
      expect(events.first.aggregate_id).to eq(aggregate_id)
      expect(events.first.sequence_number).to eq(1)
      expect(events.first.data).to eq("with ' unsafe SQL characters;\n")
    end

    it 'stores the event as JSON object' do
      # Test to ensure stored data is not accidentally doubly-encoded,
      # so query database directly instead of using `load_event`.
      row = ActiveRecord::Base.connection.exec_query(
        "SELECT event_json, event_json->>'data' AS data FROM event_records \
          WHERE aggregate_id = $1 and sequence_number = $2",
        'query_event',
        [aggregate_id, 1],
      ).first

      expect(row['data']).to eq("with ' unsafe SQL characters;\n")
      json = Sequent::Core::Oj.strict_load(row['event_json'])
      expect(json['aggregate_id']).to eq(aggregate_id)
      expect(json['sequence_number']).to eq(1)
    end

    it 'fails with OptimisticLockingError when RecordNotUnique' do
      expect do
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id:),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id:,
              ),
              [
                MyEvent.new(aggregate_id:, sequence_number: 2),
                MyEvent.new(aggregate_id:, sequence_number: 2),
              ],
            ],
          ],
        )
      end.to raise_error(Sequent::Core::EventStore::OptimisticLockingError) { |error|
        expect(error.cause).to be_a(ActiveRecord::RecordNotUnique)
      }
    end
  end

  describe '#permanently_delete_events' do
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id:),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id:,
            ),
            [MyEvent.new(aggregate_id:, sequence_number: 1)],
          ],
        ],
      )
    end

    context 'should save deleted and updated events' do
      it 'saves updated events into separate table' do
        ActiveRecord::Base.connection.exec_update(
          "UPDATE events SET event_json = '{}' WHERE aggregate_id = $1",
          'update event',
          [aggregate_id],
        )

        saved_events = ActiveRecord::Base.connection.exec_query(
          'SELECT * FROM saved_event_records WHERE aggregate_id = $1',
          'saved_events',
          [aggregate_id],
        ).to_a

        expect(saved_events.size).to eq(1)
        expect(saved_events[0]['operation']).to eq('U')
        expect(saved_events[0]['event_type']).to eq('MyEvent')
        expect(saved_events[0]['sequence_number']).to eq(1)
        expect(saved_events[0]['event_json']).to eq('{"data": null}')
      end
      it 'saves deleted events into separate table' do
        event_store.permanently_delete_event_stream(aggregate_id)

        saved_events = ActiveRecord::Base.connection.exec_query(
          'SELECT * FROM saved_event_records WHERE aggregate_id = $1',
          'saved_events',
          [aggregate_id],
        ).to_a

        expect(saved_events.size).to eq(1)
        expect(saved_events[0]['operation']).to eq('D')
        expect(saved_events[0]['event_type']).to eq('MyEvent')
        expect(saved_events[0]['sequence_number']).to eq(1)
        expect(saved_events[0]['event_json']).to eq('{"data": null}')
      end
    end

    context '#events_exists?' do
      it 'gets true for an existing aggregate' do
        expect(event_store.events_exists?(aggregate_id)).to eq(true)
      end

      it 'gets false for an non-existing aggregate' do
        expect(event_store.events_exists?(Sequent.new_uuid)).to eq(false)
      end

      it 'gets false after deletion' do
        event_store.permanently_delete_event_stream(aggregate_id)
        expect(event_store.events_exists?(aggregate_id)).to eq(false)
      end
    end
  end

  describe '#stream_exists?' do
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
            ),
            [MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)],
          ],
        ],
      )
    end

    it 'gets true for an existing aggregate' do
      expect(event_store.stream_exists?(aggregate_id)).to eq(true)
    end

    it 'gets false for an non-existing aggregate' do
      expect(event_store.stream_exists?(Sequent.new_uuid)).to eq(false)
    end

    it 'gets false after deletion' do
      event_store.permanently_delete_event_stream(aggregate_id)
      expect(event_store.stream_exists?(aggregate_id)).to eq(false)
    end
  end

  describe '#load_events' do
    it 'returns nil for non existing aggregates' do
      stream, events = event_store.load_events(aggregate_id)
      expect(stream).to be_nil
      expect(events).to be_nil
    end

    it 'returns the stream and events for existing aggregates' do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id),
            [MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)],
          ],
        ],
      )
      stream, events = event_store.load_events(aggregate_id)
      expect(stream).to be
      expect(events).to be

      expect(event_store.load_event(aggregate_id, events.first.sequence_number)).to eq(events.first)
    end

    context 'changing the partition_key and loading concurrently' do
      before do
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id,
                events_partition_key: 'Y24',
              ),
              [MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)],
            ],
          ],
        )
      end
      let(:thread_stopper) do
        Class.new do
          def initialize
            @stop = false
          end
          def stopped?
            @stop
          end
          def stop
            @stop = true
          end
        end
      end

      it 'will still allow to load the events' do
        stopper = thread_stopper.new

        reader_thread = Thread.new do
          events = []
          ActiveRecord::Base.connection_pool.with_connection do
            until stopper.stopped?
              ActiveRecord::Base.transaction do
                events << event_store.load_events(aggregate_id)&.first
              end
              sleep(0.001)
            end
          end
          events
        end
        updater_thread = Thread.new do
          1000.times do |_i|
            ActiveRecord::Base.connection_pool.with_connection do |c|
              c.exec_update(
                'UPDATE aggregates SET events_partition_key = $1 WHERE aggregate_id = $2',
                'aggregates',
                [('aa'..'zz').to_a.sample, aggregate_id],
              )
              sleep(0.0005)
            end
          end
        end
        updater_thread.join
        stopper.stop
        # wait for t1 to stop and collect its return value
        events = reader_thread.value
        # check that our test pool has some meaningful size
        expect(events.length).to be > 100

        misses = events.select(&:nil?).length
        expect(misses).to eq(0), <<~EOS
          Expected the events can always be loaded when the partition key is changed. But there are #{misses} misses.
        EOS
      end
    end

    context 'and event type caching disabled' do
      around do |example|
        current = Sequent.configuration.event_store_cache_event_types

        Sequent.configuration.event_store_cache_event_types = false

        example.run
      ensure
        Sequent.configuration.event_store_cache_event_types = current
      end
      let(:event_store) { Sequent::Core::EventStore.new }

      it 'returns the stream and events for existing aggregates' do
        TestEventForCaching = Class.new(Sequent::Core::Event)

        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id),
              [TestEventForCaching.new(aggregate_id: aggregate_id, sequence_number: 1)],
            ],
          ],
        )
        stream, events = event_store.load_events(aggregate_id)
        expect(stream).to be
        expect(events.first).to be_kind_of(TestEventForCaching)

        # redefine TestEventForCaching class (ie. simulate Rails auto-loading)
        OldTestEventForCaching = TestEventForCaching
        TestEventForCaching = Class.new(Sequent::Core::Event)

        stream, events = event_store.load_events(aggregate_id)
        expect(stream).to be
        expect(events.first).to be_kind_of(TestEventForCaching)

        expect(event_store.load_event(aggregate_id, events.first.sequence_number)).to eq(events.first)
      end
    end
  end

  describe '#load_events_for_aggregates' do
    let(:aggregate_id_1) { Sequent.new_uuid }
    let(:aggregate_id_2) { Sequent.new_uuid }

    before :each do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id_1),
            [MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 1)],
          ],
          [
            Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id_2),
            [MyEvent.new(aggregate_id: aggregate_id_2, sequence_number: 1)],
          ],
        ],
      )
    end
    it 'returns the stream and events for multiple aggregates' do
      streams_with_events = event_store.load_events_for_aggregates([aggregate_id_1, aggregate_id_2])

      expect(streams_with_events).to have(2).items
      expect(streams_with_events[0]).to have(2).items
      expect(streams_with_events[1]).to have(2).items
    end
  end

  describe 'stream events for aggregate' do
    let(:aggregate_id_1) { Sequent.new_uuid }
    let(:frozen_time) { Time.parse('2022-02-08 14:15:00 +0200') }
    let(:event_stream) { instance_of(Sequent::Core::EventStream) }
    let(:event_1) { MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 1, created_at: frozen_time) }
    let(:event_2) do
      MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 2, created_at: frozen_time + 5.minutes)
    end
    let(:event_3) do
      MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 3, created_at: frozen_time + 10.minutes)
    end
    let(:snapshot_event) do
      Sequent::Core::SnapshotEvent.new(
        aggregate_id: aggregate_id_1,
        sequence_number: 3,
        created_at: frozen_time + 8.minutes,
      )
    end

    context 'with a snapshot event' do
      before :each do
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id_1,
              ),
              [
                event_1,
                event_2,
                event_3,
              ],
            ],
          ],
        )
        event_store.store_snapshots([snapshot_event])
      end

      context 'returning events except snapshot events in order of sequence_number' do
        it 'all events up until now' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, load_until: Time.now, &block)
          end.to yield_successive_args([event_stream, event_1], [event_stream, event_2], [event_stream, event_3])
        end

        it 'all events if no load_until is passed' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, &block)
          end.to yield_successive_args([event_stream, event_1], [event_stream, event_2], [event_stream, event_3])
        end

        it 'events up until the specified time for the aggregate' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, load_until: frozen_time + 1.minute, &block)
          end.to yield_successive_args([event_stream, event_1])
        end
      end

      context 'failure' do
        it 'argument error for no events' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, load_until: frozen_time - 1.year, &block)
          end.to raise_error(ArgumentError, 'no events for this aggregate')
        end
      end

      it 'returns all events from the snapshot onwards for #load_events_for_aggregates' do
        streamed_events = event_store.load_events_for_aggregates([aggregate_id_1])
        expect(streamed_events).to have(1).items
        expect(streamed_events[0]).to have(2).items
        expect(streamed_events[0][1]).to have(2).items
      end
    end
  end

  describe 'error handling for publishing events' do
    class TestRecord; end
    class RecordingHandler < Sequent::Core::Projector
      manages_tables TestRecord
      attr_reader :recorded_events

      def initialize
        super
        @recorded_events = []
      end

      on MyEvent do |e|
        @recorded_events << e
      end
    end

    class TestRecord; end
    class FailingHandler < Sequent::Core::Projector
      manages_tables TestRecord
      Error = Class.new(RuntimeError)

      on MyEvent do |_|
        fail Error, 'Handler error'
      end
    end

    before do
      Sequent.configure do |c|
        c.event_handlers << handler
      end
    end

    context 'given a handler for MyEvent' do
      let(:handler) { RecordingHandler.new }

      it 'calls an event handler that handles the event' do
        my_event = MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id,
              ),
              [my_event],
            ],
          ],
        )
        expect(handler.recorded_events).to eq([my_event])
      end

      context 'Sequent.configuration.disable_event_handlers = true' do
        it 'does not publish any events' do
          Sequent.configuration.disable_event_handlers = true
          my_event = MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)
          event_store.commit_events(
            Sequent::Core::Command.new(aggregate_id: aggregate_id),
            [
              [
                Sequent::Core::EventStream.new(
                  aggregate_type: 'MyAggregate',
                  aggregate_id: aggregate_id,
                ),
                [my_event],
              ],
            ],
          )
          expect(handler.recorded_events).to eq([])
        end
      end
    end

    context 'given a failing event handler' do
      let(:handler) { FailingHandler.new }
      let(:my_event) { MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1) }
      subject(:publish_error) do
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id,
              ),
              [my_event],
            ],
          ],
        )
      rescue StandardError => e
        e
      end

      it { is_expected.to be_a(Sequent::Core::EventPublisher::PublishEventError) }

      it 'preserves its cause' do
        expect(publish_error.cause).to be_a(FailingHandler::Error)
        expect(publish_error.cause.message).to eq('Handler error')
      end

      it 'specifies the event handler that failed' do
        expect(publish_error.event_handler_class).to eq(FailingHandler)
      end

      it 'specifies the event that failed' do
        expect(publish_error.event).to eq(my_event)
      end
    end
  end

  describe '#replay_events_from_cursor' do
    let(:events) do
      5.times.map { |n| Sequent::Core::Event.new(aggregate_id:, sequence_number: n + 1) }
    end

    before do
      ActiveRecord::Base.connection.exec_update('TRUNCATE TABLE aggregates CASCADE')
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id:),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'Sequent::Core::AggregateRoot',
              aggregate_id:,
              events_partition_key: 'Y24',
            ),
            events,
          ],
        ],
      )
    end

    let(:get_events) do
      -> do
        Sequent.configuration.event_record_class
          .select('event_type, event_json')
          .order(:aggregate_id, :sequence_number)
      end
    end

    it 'publishes all events' do
      replay_counter = ReplayCounter.new
      Sequent.configuration.event_handlers << replay_counter
      event_store.replay_events_from_cursor(
        get_events: get_events,
        block_size: 2,
        on_progress: proc {},
      )
      expect(replay_counter.replay_count).to eq(Sequent::Core::EventRecord.count)
    end

    it 'reports progress for each block' do
      progress = 0
      progress_reported_count = 0
      on_progress = ->(n, _, _) do
        progress = n
        progress_reported_count += 1
      end
      event_store.replay_events_from_cursor(
        get_events: get_events,
        block_size: 2,
        on_progress: on_progress,
      )
      total_events = Sequent::Core::EventRecord.count
      expect(progress).to eq(total_events)
      expect(progress_reported_count).to eq((total_events / 2.0).ceil)
    end
  end

  describe '#delete_commands_without_events' do
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
            ),
            [MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)],
          ],
        ],
      )
    end

    it 'does not delete commands with associated events' do
      event_store.permanently_delete_commands_without_events(aggregate_id: aggregate_id)
      expect(Sequent::Core::CommandRecord.exists?(aggregate_id: aggregate_id)).to be_truthy
    end

    it 'deletes commands without associated events' do
      event_store.permanently_delete_event_stream(aggregate_id)
      event_store.permanently_delete_commands_without_events(aggregate_id: aggregate_id)
      expect(Sequent::Core::CommandRecord.exists?(aggregate_id: aggregate_id)).to be_falsy
    end
  end

  class ReplayCounter < Sequent::Core::Projector
    attr_reader :replay_count

    manages_no_tables
    def initialize
      super
      @replay_count = 0
    end

    on Sequent::Core::Event do |_|
      @replay_count += 1
    end
  end

  describe '#permanently_delete_commands_without_events' do
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id:),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id:,
            ),
            [MyEvent.new(aggregate_id:, sequence_number: 1)],
          ],
        ],
      )
    end

    it 'does not delete commands with associated events' do
      event_store.permanently_delete_commands_without_events(aggregate_id:)
      expect(Sequent::Core::CommandRecord.exists?(aggregate_id:)).to be_truthy
    end

    it 'deletes commands without associated events' do
      event_store.permanently_delete_event_stream(aggregate_id)
      event_store.permanently_delete_commands_without_events(aggregate_id:)
      expect(Sequent::Core::CommandRecord.exists?(aggregate_id:)).to be_falsy
    end
  end
end
