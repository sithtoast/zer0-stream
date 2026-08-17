defmodule ChatWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      @endpoint ChatWeb.Endpoint

      alias Chat.Repo
      import Ecto.Query
      import Chat.DataCase
    end
  end

  setup tags do
    Chat.DataCase.setup_sandbox(tags)
    :ok
  end
end
