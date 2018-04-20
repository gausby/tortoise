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
    case opts[:qos] do
      0 ->
        publish = %Tortoise.Package.Publish{
          topic: topic,
          payload: payload,
          retain: Keyword.get(opts, :retain, false)
        }

        Transmitter.publish(pipe, publish)

      qos when qos in [1, 2] ->
        # @todo the inflight process should be in charge of identifiers
        <<identifier::integer-size(16)>> = :crypto.strong_rand_bytes(2)

        publish = %Tortoise.Package.Publish{
          identifier: identifier,
          topic: topic,
          payload: payload,
          qos: qos,
          retain: Keyword.get(opts, :retain, false)
        }

        Inflight.track_sync(client_id, {:outgoing, publish})
    end
  end

  def subscribe(client_id, [{_, n} | _] = topics) when is_number(n) do
    <<identifier::integer-size(16)>> = :crypto.strong_rand_bytes(2)
    subscribe = Enum.into(topics, %Tortoise.Package.Subscribe{identifier: identifier})
    Inflight.track_sync(client_id, {:outgoing, subscribe}, 5000)
  end

  def subscribe(client_id, topic) do
    subscribe(client_id, [topic])
  end

  def unsubscribe(client_id, topics) when is_list(topics) do
    <<identifier::integer-size(16)>> = :crypto.strong_rand_bytes(2)
    unsubscribe = %Tortoise.Package.Unsubscribe{identifier: identifier, topics: topics}
    Inflight.track_sync(client_id, {:outgoing, unsubscribe}, 5000)
  end

  def unsubscribe(client_id, topic) do
    unsubscribe(client_id, [topic])
  end

  # defp generate_client_id() do
  #   :crypto.strong_rand_bytes(10) |> Base.encode16()
  # end
end
