ActiveRecord::Schema.define do

  create_table "command_records", :force => true do |t|
    t.string "user_id"
    t.uuid "aggregate_id"
    t.string "command_type", :null => false
    t.string "event_aggregate_id"
    t.integer "event_sequence_number"
    t.jsonb "command_json", :null => false
    t.datetime "created_at", :null => false
  end

  add_index "command_records", ["event_aggregate_id", 'event_sequence_number'], :name => "index_command_records_on_event"

  create_table "stream_records", :primary_key => ['aggregate_id'], :force => true do |t|
    t.datetime "created_at", :null => false
    t.string "aggregate_type", :null => false
    t.uuid "aggregate_id", :null => false
    t.integer "snapshot_threshold"
  end

  create_table "event_records", :primary_key => ["aggregate_id", "sequence_number"], :force => true do |t|
    t.uuid "aggregate_id", :null => false
    t.integer "sequence_number", :null => false
    t.datetime "created_at", :null => false
    t.string "event_type", :null => false
    t.jsonb "event_json", :null => false
    t.integer "command_record_id", :null => false
    t.bigint "xact_id", :null => false
  end

  add_index "event_records", ["command_record_id"], :name => "index_event_records_on_command_record_id"
  add_index "event_records", ["event_type"], :name => "index_event_records_on_event_type"
  add_index "event_records", ["created_at"], :name => "index_event_records_on_created_at"
  add_index "event_records", ["xact_id"], :name => "index_event_records_on_xact_id"

  execute %Q{
ALTER TABLE event_records ALTER COLUMN xact_id SET DEFAULT pg_current_xact_id()::text::bigint
}
  execute %q{
ALTER TABLE event_records ADD CONSTRAINT command_fkey FOREIGN KEY (command_record_id) REFERENCES command_records (id)
}
  execute %q{
ALTER TABLE event_records ADD CONSTRAINT stream_fkey FOREIGN KEY (aggregate_id) REFERENCES stream_records (aggregate_id)
}

  create_table "snapshot_records", :primary_key => ["aggregate_id", "sequence_number"], :force => true do |t|
    t.uuid "aggregate_id", :null => false
    t.integer "sequence_number", :null => false
    t.datetime "created_at", :null => false
    t.text "snapshot_type", :null => false
    t.jsonb "snapshot_json", :null => false
  end

  execute %q{
ALTER TABLE snapshot_records ADD CONSTRAINT stream_fkey FOREIGN KEY (aggregate_id) REFERENCES stream_records (aggregate_id)
}
end
