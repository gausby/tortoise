defmodule Tortoise do
  @moduledoc """
  Documentation for Tortoise.
  """

  @doc """
  Publish a message to the MQTT broker
  """
  defdelegate publish(client_id, topic, payload \\ nil, opts \\ []), to: Tortoise.Connection

  defdelegate publish_sync(client_id, topic, payload \\ nil, opts \\ [], timeout \\ :infinity),
    to: Tortoise.Connection

  defdelegate subscribe(client_id, topics, opts \\ []), to: Tortoise.Connection

  defdelegate unsubscribe(client_id, topics, opts \\ []), to: Tortoise.Connection

  # defp generate_client_id() do
  #   :crypto.strong_rand_bytes(10) |> Base.encode16()
  # end
end
