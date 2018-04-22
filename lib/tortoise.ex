defmodule Tortoise do
  use Application

  alias Tortoise.Connection.{Transmitter, Inflight}

  @moduledoc """
  Documentation for Tortoise.
  """

  @doc """
  Start the application supervisor
  """
  def start(:normal, _args) do
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
  def publish(%{client_id: client_id} = pipe, topic, payload, opts \\ [qos: 0]) do
    publish = %Tortoise.Package.Publish{
      topic: topic,
      qos: opts.qos,
      payload: payload,
      retain: Keyword.get(opts, :retain, false)
    }

    if opts.qos in [1, 2] do
      Inflight.track_sync(client_id, {:outgoing, publish})
    else
      Transmitter.publish(pipe, publish)
    end
  end

  def subscribe(client_id, [{_, n} | _] = topics) when is_number(n) do
    subscribe = Enum.into(topics, %Tortoise.Package.Subscribe{})
    Inflight.track_sync(client_id, {:outgoing, subscribe}, 5000)
  end

  def subscribe(client_id, topic) do
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
