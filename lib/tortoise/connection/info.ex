defmodule Tortoise.Connection.Info do
  @enforce_keys [:keep_alive]
  defstruct client_id: nil,
            keep_alive: nil,
            capabilities: nil

  alias Tortoise.Package.{Connect, Connack}

  def merge(
        %Connect{keep_alive: keep_alive},
        %Connack{reason: :success} = connack
      ) do
    # if no server_keep_alive is set we should use the one set by the client
    keep_alive = Keyword.get(connack.properties, :server_keep_alive, keep_alive)

    struct!(__MODULE__,
      keep_alive: keep_alive,
      capabilities: struct!(%__MODULE__.Capabilities{}, connack.properties)
    )
  end
end
