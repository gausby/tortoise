defmodule Tortoise do
  @moduledoc """
  Documentation for Tortoise.
  """

  @doc """
  Publish a message to the MQTT broker.

  The publish function takes require a `client_id` and a valid MQTT
  topic. If no `payload` is set an empty zero byte message will get
  send to the broker.

  Optionally an options list is accepted, which allow the user to
  configure the publish as described in the following section.

  ## Options

    * `retain` indicates, when set to `true`, that the broker should
      retain the message for the topic. Retained messages are
      delivered to client when they subscribe to the topic. Only one
      message can be retained for a given topic, so sending a new one
      will overwrite the old. `retain` defaults to `false`.

    * `qos` set the quality of service. The `qos` defaults to `0`.

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
