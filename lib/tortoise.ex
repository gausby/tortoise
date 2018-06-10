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

  @doc """
  Will publish a message to the broker. This is very similar to
  `Tortoise.publish/4` with the difference that it will block the
  calling process until the message has been delivered; the
  configuration options are the same with the addition of the
  `timeout` option which specify how long we are willing to wait for a
  reply. Per default the timeout is set to `:infinity`, it is
  advisable to set it to a reasonable amount in milliseconds as it
  otherwise could block forever.

      msg = "Hello, from the World of Tomorrow !"
      case Tortoise.publish_sync("my_client_id", "foo/bar", msg, qos: 2, timeout: 200) do
        :ok ->
          :done

        {:error, :timeout} ->
          :timeout
      end

  Notice: It does not make sense to use `publish_sync/4` on a publish
  that has a QoS=0, because that will return instantly anyways. It is
  made possible for consistency, and it is the default QoS.

  See the documentation for `Tortoise.publish/4` for configuration.
  """
  defdelegate publish_sync(client_id, topic, payload \\ nil, opts \\ []),
    to: Tortoise.Connection

  @doc """
  Subscribe to one or more topics using topic filters on `client_id`

  The topic filter should be a 2-tuple, `{topic_filter, qos}`, where
  the `topic_filter` is a valid MQTT topic filter, and `qos` an
  integer value 0 through 2.

  Multiple topics can be given as a list.
  """
  defdelegate subscribe(client_id, topics, opts \\ []),
    to: Tortoise.Connection

  defdelegate subscribe_sync(client_id, topics, opts \\ []),
    to: Tortoise.Connection

  @doc """
  Unsubscribe from one of more topic filters. The topic filters are
  given as strings. Multiple topic filters can be given at once by
  passing in a list of strings.
  """
  defdelegate unsubscribe(client_id, topics, opts \\ []),
    to: Tortoise.Connection

  defdelegate unsubscribe_sync(client_id, topics, opts \\ []),
    to: Tortoise.Connection
end
