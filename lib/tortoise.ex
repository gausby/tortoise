defmodule Tortoise do
  @moduledoc """
  Documentation for Tortoise.
  """

  alias Tortoise.Connection.Inflight

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
