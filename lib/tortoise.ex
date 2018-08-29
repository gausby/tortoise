defmodule Tortoise do
  @moduledoc """
  A MQTT client for Elixir.

  `Tortoise` provides ways of publishing messages to, and receiving
  messages from one or many MQTT brokers via TCP or SSL. The design
  philosophy of Tortoise is to hide the protocol specific details from
  the user, and expose interfaces and a connection life cycle that
  should feel natural to Elixir, while not limiting the capability of
  what one can do with the MQTT protocol.

  First off, connection to a broker happens through a connection
  specification. This results in a process that can be supervised,
  either by the application the connection should live and die with,
  or by being supervised by the Tortoise application itself. Once the
  connection is established the Tortoise application should do its
  best to keep that connection open, by automatically sending keep
  alive messages (as the protocol specifies), and eventually attempt
  to reconnect if the connection should drop.

  Secondly, a connection is specified with a user defined callback
  module, following the `Tortoise.Handler`-behaviour, which allow the
  user to hook into certain events happening in the life cycle of the
  connection. This way code can get executed when:

    - The connection is established
    - The client has been disconnected from the broker
    - A topic filter subscription has been accepted (or declined)
    - A topic filter has been successfully unsubscribed
    - A message is received on one of the subscribed topic filters

  Besides this there are hooks for the usual life-cycle events one
  would expect, such as `init/1` and `terminate/2`.

  Thirdly, publishing is handled in such a way that the semantics of
  the levels of Quality of Service, specified by the MQTT protocol, is
  mapped to the Elixir message passing semantics. Tortoise expose an
  interface for publishing messages that hide the protocol details of
  message delivery (retrieval of acknowledge, release, complete
  messages) and instead provide `Tortoise.publish/4` which will
  deliver the message to the broker and receive a response in the
  process mailbox when a message with a QoS>0 has been handed to the
  server. This allow the user to keep track of the messages that has
  been delivered, or simply by using the `Tortoise.publish_sync/4`
  form that will block the calling process until the message has been
  safely handed to the broker. Messages with QoS1 or QoS2 are stored
  in a process until they are delivered, so once they are published
  the client should retry delivery to make sure they reach their
  destination.

  An alternative way of posting messages is implemented in
  `Tortoise.Pipe`, which provide a data structure that among other
  things keep a reference to the connection socket. This allow for an
  efficient way of posting messages because the data can get shot
  directly onto the wire without having to copy the message between
  processes (unless the message has a QoS of 1 or 2, in which case
  they will end up in a process to ensure they will get
  delivered). The pipe will automatically renew its connection socket
  if the connection has been dropped, so ideally this message sending
  approach should be fast and efficient.
  """

  alias Tortoise.Package
  alias Tortoise.Connection
  alias Tortoise.Connection.Inflight

  @type client_id() :: atom() | String.t()
  @type package_identifier() :: 0x0001..0xFFFF | nil

  @doc """
  Publish a message to the MQTT broker.

  The publish function requires a `client_id` and a valid MQTT
  topic. If no `payload` is set an empty zero byte message will get
  send to the broker.

  Optionally an options list can get passed to the publish, making it
  possible to specify if the message should be retained on the server,
  and with what quality of service the message should be published
  with.

    * `retain` indicates, when set to `true`, that the broker should
      retain the message for the topic. Retained messages are
      delivered to clients when they subscribe to the topic. Only one
      message at a time can be retained for a given topic, so sending
      a new one will overwrite the old. `retain` defaults to `false`.

    * `qos` set the quality of service, and integer of 0, 1, or 2. The
      `qos` defaults to `0`.

  Publishing a message with the payload *hello* to to topic *foo/bar*
  with a *QoS1* could look like this:

      Tortoise.publish("client_id", "foo/bar", "hello", qos: 1)

  Notice that if you want to send a message with an empty payload with
  options you will have to set to payload to nil like this:

      Tortoise.publish("client_id", "foo/bar", nil, retain: true)

  ## Return Values

  The specified Quality of Service for a given publish will alter the
  behaviour of the return value. When publishing a message with a QoS0
  an `:ok` will simply get returned. This is because a QoS0 is a "fire
  and forget." There are no quality of service so no efforts are made
  to ensure that the message will reach its destination (though it very
  likely will).

      :ok = Tortoise.publish("client_id", "foo/bar", nil, qos: 0)

  When a message is published using either a QoS1 or QoS2, Tortoise
  will ensure that the message is delivered. A unique reference will
  get returned and eventually a message will get delivered to the
  process mailbox, containing the result of the publish when it has
  been handed over:

      {:ok, ref} = Tortoise.publish("client_id", "foo/bar", nil, qos: 2)
      receive do
        {{Tortoise, "client_id"}, ^ref, result} ->
          IO.inspect({:result, result})
      after
        5000 ->
          {:error, :timeout}
      end

  Be sure to implement a `handle_info/2` in `GenServer` processes that
  publish messages using Tortoise.publish/4. Notice that the returned
  message has a structure:

      {{Tortoise, "client_id"}, ^ref, result}

  It is possible to send to multiple clients and blanket match on
  results designated for a given client id, and the message is tagged
  with `Tortoise` so it is easy to see where the message originated
  from.
  """
  def publish(client_id, topic, payload \\ nil, opts \\ []) do
    qos = Keyword.get(opts, :qos, 0)

    publish = %Package.Publish{
      topic: topic,
      qos: qos,
      payload: payload,
      retain: Keyword.get(opts, :retain, false)
    }

    with {:ok, {transport, socket}} <- Connection.connection(client_id) do
      case publish do
        %Package.Publish{qos: 0} ->
          encoded_publish = Package.encode(publish)
          apply(transport, :send, [socket, encoded_publish])

        %Package.Publish{qos: qos} when qos in [1, 2] ->
          Inflight.track(client_id, {:outgoing, publish})
      end
    else
      {:error, :unknown_connection} ->
        {:error, :unknown_connection}
    end
  end

  @doc """
  Synchronously send a message to the MQTT broker.

  This is very similar to `Tortoise.publish/4` with the difference
  that it will block the calling process until the message has been
  handed over to the server; the configuration options are the same
  with the addition of the `timeout` option which specifies how long
  we are willing to wait for a reply. Per default the timeout is set
  to `:infinity`, it is advisable to set it to a reasonable amount in
  milliseconds as it otherwise could block forever.

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
  def publish_sync(client_id, topic, payload \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    qos = Keyword.get(opts, :qos, 0)

    publish = %Package.Publish{
      topic: topic,
      qos: qos,
      payload: payload,
      retain: Keyword.get(opts, :retain, false)
    }

    with {:ok, {transport, socket}} <- Connection.connection(client_id) do
      case publish do
        %Package.Publish{qos: 0} ->
          encoded_publish = Package.encode(publish)
          apply(transport, :send, [socket, encoded_publish])

        %Package.Publish{qos: qos} when qos in [1, 2] ->
          Inflight.track_sync(client_id, {:outgoing, publish}, timeout)
      end
    else
      {:error, :unknown_connection} ->
        {:error, :unknown_connection}
    end
  end
end
