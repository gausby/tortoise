defmodule Tortoise.TestGenerators do
  @moduledoc """
  EQC generators for generating variables and data structures useful
  for testing MQTT
  """
  use EQC.ExUnit

  alias Tortoise.Package

  def gen_topic() do
    let topic_list <- non_empty(list(5, gen_topic_level())) do
      Enum.join(topic_list, "/")
    end
  end

  def gen_topic_filter() do
    let topic_list <- non_empty(list(5, gen_topic_level())) do
      let {_matching?, filter} <- gen_filter_from_topic(topic_list) do
        Enum.join(filter, "/")
      end
    end
  end

  defp gen_topic_level() do
    such_that topic <- non_empty(utf8()) do
      not String.contains?(topic, ["/", "+", "#"])
    end
  end

  # - - -
  defp gen_filter_from_topic(topic) do
    {_matching?, _filter} = gen_filter(:cont, true, topic, [])
  end

  defp gen_filter(_status, matching?, _, ["#" | _] = acc) do
    let(result <- Enum.reverse(acc), do: {matching?, result})
  end

  defp gen_filter(:stop, matching?, [t], acc) do
    let(result <- Enum.reverse([t | acc]), do: {matching?, result})
  end

  defp gen_filter(:stop, _matching?, _topic_list, acc) do
    let(result <- Enum.reverse(acc), do: {false, result})
  end

  defp gen_filter(status, matching?, [], acc) do
    frequency([
      {20, {matching?, lazy(do: Enum.reverse(acc))}},
      {5, gen_extra_filter_topic(status, matching?, acc)}
    ])
  end

  defp gen_filter(status, matching?, [t | ts], acc) do
    frequency([
      # keep
      {15, gen_filter(status, matching?, ts, [t | acc])},
      # one level filter
      {20, gen_filter(status, matching?, ts, ["+" | acc])},
      # mutate
      {10, gen_filter(status, false, ts, [alter_topic_level(t) | acc])},
      # multi-level filter
      {5, gen_filter(status, matching?, [], ["#" | acc])},
      # early bail out
      {5, gen_filter(:stop, matching?, [t | ts], acc)}
    ])
  end

  defp gen_extra_filter_topic(status, _matching?, acc) do
    let extra_topic <- gen_topic_level() do
      gen_filter(status, false, [extra_topic], acc)
    end
  end

  # Given a specific topic level return a different one
  defp alter_topic_level(topic_level) do
    such_that mutation <- gen_topic_level() do
      mutation != topic_level
    end
  end

  # --------------------------------------------------------------------
  def gen_identifier() do
    choose(0x0001, 0xFFFF)
  end

  def gen_qos() do
    choose(0, 2)
  end

  @doc """
  Generate a valid connect message
  """
  def gen_connect() do
    let last_will <-
          oneof([
            nil,
            %Package.Publish{
              topic: gen_topic(),
              payload: oneof([non_empty(binary()), nil]),
              qos: gen_qos(),
              retain: bool()
            }
          ]) do
      # zero byte client id is allowed, but clean session should be set to true
      let connect <- %Package.Connect{
            # The Server MUST allow ClientIds which are between 1 and 23
            # UTF-8 encoded bytes in length, and that contain only the
            # characters
            # "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            # [MQTT-3.1.3-5].

            # The Server MAY allow ClientId’s that contain more than 23
            # encoded bytes. The Server MAY allow ClientId’s that contain
            # characters not included in the list given above.
            client_id: binary(),
            user_name: oneof([nil, utf8()]),
            password: oneof([nil, utf8()]),
            clean_session: bool(),
            keep_alive: choose(0, 65535),
            will: last_will
          } do
        connect
      end
    end
  end

  @doc """
  Generate a valid connack (connection acknowledgement) message
  """
  def gen_connack() do
    let connack <- %Package.Connack{
          session_present: bool(),
          status:
            oneof([
              :accepted,
              {:refused, :unacceptable_protocol_version},
              {:refused, :identifier_rejected},
              {:refused, :server_unavailable},
              {:refused, :bad_user_name_or_password},
              {:refused, :not_authorized}
            ])
        } do
      connack
    end
  end

  @doc """
  Generate a valid publish message.

  A publish message with a quality of zero will not have an identifier
  or ever be a duplicate message, so we generate the quality of
  service first and decide if we should generate values for those
  values depending on the value of the generated QoS.
  """
  def gen_publish() do
    let qos <- gen_qos() do
      %{
        do_gen_publish(qos)
        | topic: gen_topic(),
          payload: oneof([non_empty(binary()), nil]),
          retain: bool()
      }
    end
  end

  defp do_gen_publish(0) do
    %Package.Publish{identifier: nil, qos: 0, dup: false}
  end

  defp do_gen_publish(qos) do
    %Package.Publish{
      identifier: gen_identifier(),
      qos: qos,
      dup: bool()
    }
  end

  @doc """
  Generate a valid subscribe message.

  The message will get populated with one or more topic filters, each
  with a quality of service between 0 and 2.
  """
  def gen_subscribe() do
    let subscribe <- %Package.Subscribe{
          identifier: gen_identifier(),
          topics: non_empty(list({gen_topic_filter(), gen_qos()}))
        } do
      subscribe
    end
  end

  def gen_suback() do
    let suback <- %Package.Suback{
          identifier: choose(0x0001, 0xFFFF),
          acks: non_empty(list(oneof([{:ok, gen_qos()}, {:error, :access_denied}])))
        } do
      suback
    end
  end

  @doc """
  Generate a valid unsubscribe message.
  """
  def gen_unsubscribe() do
    let unsubscribe <- %Package.Unsubscribe{
          identifier: gen_identifier(),
          topics: list(gen_topic_filter())
        } do
      unsubscribe
    end
  end

  def gen_unsuback() do
    let unsuback <- %Package.Unsuback{
          identifier: gen_identifier()
        } do
      unsuback
    end
  end

  def gen_puback() do
    let puback <- %Package.Puback{
          identifier: gen_identifier()
        } do
      puback
    end
  end

  def gen_pubcomp() do
    let pubcomp <- %Package.Pubcomp{
          identifier: gen_identifier()
        } do
      pubcomp
    end
  end

  def gen_pubrel() do
    let pubrel <- %Package.Pubrel{
          identifier: gen_identifier()
        } do
      pubrel
    end
  end

  def gen_pubrec() do
    let pubrec <- %Package.Pubrec{
          identifier: gen_identifier()
        } do
      pubrec
    end
  end
end

defmodule Tortoise.TestTCPTunnel do
  @moduledoc """
  Create a TCP-tunnel making it possible to use :gen_tcp.send/2-3 to
  send to the client_socket and assert on the received data on the
  server_socket.

  This work for our Transmitter-module which is handled a TCP-socket
  from the Receiver.
  """
  use GenServer

  defstruct [:socket, :ip, :port]

  # Client API
  def start_link() do
    initial_state = %__MODULE__{}
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def new() do
    {ref, {ip, port}} = GenServer.call(__MODULE__, :create)
    {:ok, client_socket} = :gen_tcp.connect(ip, port, [:binary, active: false])

    receive do
      {:server_socket, ^ref, server_socket} ->
        {:ok, client_socket, server_socket}
    after
      1000 ->
        throw("Could not create TCP test tunnel")
    end
  end

  # Server callbacks
  def init(state) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {ip, port}} = :inet.sockname(socket)
    {:ok, %{state | socket: socket, ip: ip, port: port}}
  end

  def handle_call(:create, {process_pid, ref} = from, state) do
    GenServer.reply(from, {ref, {state.ip, state.port}})
    # the process should now wait for the caller to accept the socket
    {:ok, server} = :gen_tcp.accept(state.socket, 200)
    :ok = :gen_tcp.controlling_process(server, process_pid)
    send(process_pid, {:server_socket, ref, server})
    {:noreply, state}
  end
end

{:ok, _acceptor_pid} = Tortoise.TestTCPTunnel.start_link()

ExUnit.start()
