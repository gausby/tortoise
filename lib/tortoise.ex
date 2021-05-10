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

  @typedoc """
  An identifier used to identify the client on the server.

  Most servers accept a maximum of 23 UTF-8 encode bytes for a client
  id, and only the characters:

    - "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  Tortoise accept atoms as client ids but they it will be converted to
  a string before going on the wire. Be careful with atoms such as
  `Example` because they are expanded to the atom `:"Elixir.Example"`,
  it is really easy to hit the maximum byte limit. Solving this is
  easy, just add a `:` before the client id such as `:Example`.
  """
  @type client_id() :: atom() | String.t()

  @typedoc """
  A 16-bit number identifying a message in a message exchange.

  Some MQTT packages are part of a message exchange and need an
  identifier so the server and client can distinct between multiple
  in-flight messages.

  Tortoise will assign package identifier to packages that need them,
  so outside of tests (where it is beneficial to assert on the
  identifier of a package) it should be set by tortoise itself; so
  just leave it as `nil`.
  """
  @type package_identifier() :: 0x0001..0xFFFF | nil

  @typedoc """
  What Quality of Service (QoS) mode should be used.

  Quality of Service is one of 0, 1, and 2 denoting the following:

  - `0` no quality of service. The message is a fire and forget.

  - `1` at least once delivery. The receiver will respond with an
    acknowledge message, so the sender will be certain that the
    message has reached the destination. It is possible that a message
    will be delivered twice though, as the package identifier for a
    publish will be relinquished when the message has been
    acknowledged, so a package with the same identifier will be
    treated as a new message though it might be a re-transmission.

  - `2` exactly once delivery. The receiver will only receive the
    message once. This happens by having a more elaborate message
    exchange than the QoS=1 variant.

  There are a difference in the semantics of assigning a QoS to a
  publish and a subscription. When assigned to a publish the message
  will get delivered to the server with the requested QoS; that is if
  it accept that level of QoS for the given topic.

  When used in the context of a subscription it should be read as *the
  maximum QoS*. When messages are published to the subscribed topic
  the message will get on-warded with the same topic as it was
  delivered with, or downgraded to the maximum QoS of the subscription
  for the given subscribing client. That is, if the client subscribe
  with a maximum QoS=2 and a message is published to said topic with a
  QoS=1, the message will get downgraded to QoS=1 when on-warded to
  the client.
  """
  @type qos() :: 0..2

  @typedoc """
  A topic for a message.

  According to the MQTT 3.1.1 specification a valid topic must be at
  least one character long. They are case sensitive and can include
  space characters.

  MQTT topics consist of topic levels which are delimited with forward
  slashes `/`. A topic with a leading or trailing forward slash is
  allowed but they create distinct topics from the ones without;
  `/sports/tennis/results` are different from
  `sports/tennis/results`. While a topic level normally require at
  least one character the topic `/` (a single forward slash) is valid.

  The server will drop the connection if it receive an invalid topic.
  """
  @type topic() :: String.t()

  @typedoc """
  A topic filter for a subscription.

  The topic filter is different from a `topic` because it is allowed
  to contain wildcard characters:

  - `+` is a single level wildcard which is allowed to stand on any
    position in the topic filter. For instance: `sport/+/results` will
    match `sport/tennis/results`, `sport/soccer/results`, etc.

  - `#` is a multi-level wildcard and is only allowed to be on the
    last position of the topic filter. For instance: `sport/#` will
    match `sport/tennis/results`, `sport/tennis/announcements`, etc.

  The server will reject any invalid topic filter and close the
  connection.
  """
  @type topic_filter() :: String.t()

  @typedoc """
  An optional message payload.

  A message can optionally have a payload. The payload is a series of
  bytes and for MQTT 3.1.1 the payload has no defined structure; any
  series of bytes will do, and the client has to make sense of it.

  The payload will be `nil` if there is no payload. This is done to
  distinct between a zero byte binary and an empty payload.
  """
  @type payload() :: binary() | nil

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
  @spec publish(client_id(), topic(), payload, [options]) ::
          :ok | {:ok, reference()} | {:error, :unknown_connection} | {:error, :timeout}
        when payload: binary() | nil,
             options:
               {:qos, qos()}
               | {:retain, boolean()}
               | {:identifier, package_identifier()}
               | {:timeout, non_neg_integer()}
  def publish(client_id, topic, payload \\ nil, opts \\ []) do
    qos = Keyword.get(opts, :qos, 0)

    publish = %Package.Publish{
      topic: topic,
      qos: qos,
      payload: payload,
      retain: Keyword.get(opts, :retain, false)
    }

    timeout = Keyword.get(opts, :timeout, :infinity)

    with {:ok, {transport, socket}} <- Connection.connection(client_id, timeout: timeout) do
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

      {:error, :timeout} ->
        {:error, :timeout}
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
  @spec publish_sync(client_id(), topic(), payload, [options]) ::
          :ok | {:error, :unknown_connection} | {:error, :timeout}
        when payload: binary() | nil,
             options:
               {:qos, qos()}
               | {:retain, boolean()}
               | {:identifier, package_identifier()}
               | {:timeout, timeout()}
  def publish_sync(client_id, topic, payload \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    qos = Keyword.get(opts, :qos, 0)

    publish = %Package.Publish{
      topic: topic,
      qos: qos,
      payload: payload,
      retain: Keyword.get(opts, :retain, false)
    }

    with {:ok, {transport, socket}} <- Connection.connection(client_id, timeout: timeout) do
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

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end
end
