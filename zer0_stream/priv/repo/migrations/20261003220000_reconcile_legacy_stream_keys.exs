defmodule Zer0Stream.Repo.Migrations.ReconcileLegacyStreamKeys do
  use Ecto.Migration

  # 20260814230000_create_streaming_control_plane was edited after it first ran:
  # stream keys moved from streams (stream_id) to creators (creator_id) and
  # streams.creator_id became unique. Databases created before that edit never
  # got either change, so key rotation failed with "column creator_id does not
  # exist". Bring such databases up to date; on newer ones this is a no-op.
  def up do
    execute("""
    ALTER TABLE stream_keys
      ADD COLUMN IF NOT EXISTS creator_id bigint REFERENCES creators(id) ON DELETE CASCADE
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'stream_keys' AND column_name = 'stream_id'
      ) THEN
        UPDATE stream_keys AS k SET creator_id = s.creator_id
        FROM streams AS s
        WHERE k.stream_id = s.id AND k.creator_id IS NULL;

        ALTER TABLE stream_keys DROP COLUMN stream_id;
      END IF;
    END $$
    """)

    # A key that can't be tied to a creator can't authenticate anyone.
    execute("DELETE FROM stream_keys WHERE creator_id IS NULL")
    execute("ALTER TABLE stream_keys ALTER COLUMN creator_id SET NOT NULL")
    execute("CREATE INDEX IF NOT EXISTS stream_keys_creator_id_index ON stream_keys (creator_id)")

    # Make streams.creator_id unique, unless existing rows would violate it.
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = 'streams_creator_id_index' AND i.indisunique
      ) THEN
        IF EXISTS (SELECT creator_id FROM streams GROUP BY creator_id HAVING count(*) > 1) THEN
          RAISE NOTICE 'streams has several rows per creator; leaving streams_creator_id_index non-unique';
        ELSE
          DROP INDEX IF EXISTS streams_creator_id_index;
          CREATE UNIQUE INDEX streams_creator_id_index ON streams (creator_id);
        END IF;
      END IF;
    END $$
    """)
  end

  def down, do: :ok
end
