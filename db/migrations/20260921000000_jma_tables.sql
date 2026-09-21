-- Create "jma_item" table
CREATE TABLE sea.jma_item (
  item_url text NOT NULL,
  feed_url text NOT NULL,
  guid text NULL,
  title text NULL,
  published_at timestamptz NULL,
  state text NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0,
  last_attempt_at timestamptz NULL,
  http_status integer NULL,
  error text NULL,
  identifier text NULL,
  raw_xml text NULL,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_url)
);
-- Create index "idx_jma_item_state_first_seen" to table: "jma_item"
CREATE INDEX idx_jma_item_state_first_seen ON sea.jma_item (state, first_seen_at DESC);
-- Create "jma_message" table
CREATE TABLE sea.jma_message (
  identifier text NOT NULL,
  item_url text NOT NULL,
  feed_url text NOT NULL,
  control_title text NOT NULL,
  status text NOT NULL,
  info_type text NOT NULL,
  event_id text NULL,
  series_key text NULL,
  sent timestamptz NOT NULL,
  headline text NULL,
  description text NULL,
  raw_xml text NOT NULL,
  normalized boolean NOT NULL DEFAULT false,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (identifier),
  CONSTRAINT jma_message_item_url_fkey FOREIGN KEY (item_url) REFERENCES sea.jma_item (item_url) ON UPDATE NO ACTION ON DELETE NO ACTION
);
-- Create index "idx_jma_message_event_id" to table: "jma_message"
CREATE INDEX idx_jma_message_event_id ON sea.jma_message (event_id) WHERE (event_id IS NOT NULL);
-- Create index "idx_jma_message_series_key" to table: "jma_message"
CREATE INDEX idx_jma_message_series_key ON sea.jma_message (series_key) WHERE (series_key IS NOT NULL);
-- Create index "idx_jma_message_sent" to table: "jma_message"
CREATE INDEX idx_jma_message_sent ON sea.jma_message (sent DESC);
-- Create "jma_series" table
CREATE TABLE sea.jma_series (
  series_key text NOT NULL,
  kind text NOT NULL,
  latest_sent timestamptz NOT NULL,
  is_cancelled boolean NOT NULL DEFAULT false,
  latest_identifier text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (series_key)
);
-- Create index "idx_jma_series_updated_at" to table: "jma_series"
CREATE INDEX idx_jma_series_updated_at ON sea.jma_series (updated_at DESC);

