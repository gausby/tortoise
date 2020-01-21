defmodule Tortoise.Connection.Info do
  @enforce_keys [:keep_alive]
  defstruct client_id: nil,
            subscriptions: %{},
            keep_alive: nil,
            receiver_pid: nil,
            capabilities: nil

  alias __MODULE__
  alias Tortoise.Package.{Connect, Connack}

  def merge(
        %Connect{keep_alive: keep_alive} = connect,
        %Connack{reason: :success} = connack
      ) do
    # if no server_keep_alive is set we should use the one set by the client
    keep_alive = Keyword.get(connack.properties, :server_keep_alive, keep_alive)

    struct!(Info,
      keep_alive: keep_alive,
      client_id: get_client_id(connect, connack),
      capabilities: struct!(Info.Capabilities, connack.properties)
    )
  end

  # If the client does not specify a client id it should look for a
  # server assigned client identifier in the connack properties. It
  # would be a error if this is not specified
  defp get_client_id(%Connect{client_id: nil}, %Connack{properties: properties}) do
    case Keyword.get(properties, :assigned_client_identifier) do
      nil ->
        raise "No client id specified"

      client_id when is_binary(client_id) ->
        client_id
    end
  end

  defp get_client_id(%Connect{client_id: client_id}, %Connack{}) do
    client_id
  end
end
