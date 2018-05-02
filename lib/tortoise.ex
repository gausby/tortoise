defmodule Tortoise do
  use Application

  alias Tortoise.Connection.Inflight

  @moduledoc """
  Documentation for Tortoise.
  """

  @doc """
  Start the application supervisor
  """
  def start(_type, _args) do
    # read configuration and start connections
    # start with client_id, and driver from config

    children = [
      {Registry, [keys: :unique, name: Registry.Tortoise]},
      {Tortoise.Supervisor, [strategy: :one_for_one]}
    ]

    opts = [strategy: :one_for_one, name: Tortoise]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Publish a message to the MQTT broker
  """
  defdelegate publish(client_id, topic, payload \\ nil, opts \\ []), to: Tortoise.Connection

  defdelegate publish_sync(client_id, topic, payload \\ nil, opts \\ [], timeout \\ :infinity),
    to: Tortoise.Connection

  def subscribe(client_id, [{_, n} | _] = topics) when is_number(n) do
    subscribe = Enum.into(topics, %Tortoise.Package.Subscribe{})
    Inflight.track_sync(client_id, {:outgoing, subscribe}, 5000)
  end

  def subscribe(client_id, {_, n} = topic) when is_number(n) do
    subscribe(client_id, [topic])
  end

  def unsubscribe(client_id, topics) when is_list(topics) do
    unsubscribe = %Tortoise.Package.Unsubscribe{topics: topics}
    Inflight.track_sync(client_id, {:outgoing, unsubscribe}, 5000)
  end

  def unsubscribe(client_id, topic) do
    unsubscribe(client_id, [topic])
  end

  # defp generate_client_id() do
  #   :crypto.strong_rand_bytes(10) |> Base.encode16()
  # end
end
