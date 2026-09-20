defmodule Zer0Media.LLHLS.LocalStore do
  @moduledoc "Atomic local object publication. The origin carries metadata, never media bytes."

  def put(path, bytes, mode \\ :immutable) do
    File.mkdir_p!(Path.dirname(path))

    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- File.write(temporary, bytes, [:binary, :exclusive]) do
        case mode do
          :replace ->
            File.rename(temporary, path)

          :immutable ->
            # Linking publishes a complete inode without overwriting an existing
            # object. The temporary file is on the same filesystem.
            File.ln(temporary, path)
        end
      end
    after
      File.rm(temporary)
    end
  end
end
