defmodule Tortoise.Connection.Receiver do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.{Events, Transport}

  defstruct client_id: nil, transport: nil, socket: nil, buffer: <<>>, parent: nil
  alias __MODULE__, as: State

  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)

    data = %State{
      client_id: client_id,
      transport: Keyword.fetch!(opts, :transport),
      parent: Keyword.fetch!(opts, :parent)
    }

    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  def whereis(client_id) do
    __MODULE__
    |> Tortoise.Registry.reg_name(client_id)
    |> Registry.whereis_name()
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def connect(client_id) do
    GenStateMachine.call(via_name(client_id), :connect)
  end

  @impl true
  def init(%State{} = data) do
    send(data.parent, {{Tortoise, data.client_id}, __MODULE__, {:ready, self()}})
    {:ok, :disconnected, data}
  end

  def terminate(_reason, _state) do
    :ok
  end

  @impl true
  # receiving data on the network connection
  def handle_event(:info, {transport, socket, tcp_data}, _, %{socket: socket} = data)
      when transport in [:tcp, :ssl, ScriptedTransport] do
    next_actions = [
      {:next_event, :internal, :activate_socket},
      {:next_event, :internal, :consume_buffer}
    ]

    new_data = %{data | buffer: <<data.buffer::binary, tcp_data::binary>>}
    {:keep_state, new_data, next_actions}
  end

  def handle_event(:info, unknown_info, _, data) do
    {:stop, {:unknown_info, unknown_info}, data}
  end

  # activate network socket for incoming traffic
  def handle_event(
        :internal,
        :activate_socket,
        _state_name,
        %State{transport: %Transport{type: transport}} = data
      ) do
    case transport.setopts(data.socket, active: :once) do
      :ok ->
        :keep_state_and_data

      {:error, :einval} ->
        # @todo consider if there could be a buffer we should drain at this point
        {:next_state, :disconnected, data}
    end
  end

  # consume buffer
  def handle_event(:internal, :consume_buffer, _current_name, %{buffer: <<>>}) do
    :keep_state_and_data
  end

  # consuming message
  def handle_event(
        :internal,
        :consume_buffer,
        {:connected, {:receiving_variable, length}},
        %State{buffer: buffer} = data
      )
      when byte_size(buffer) >= length do
    <<package::binary-size(length), rest::binary>> = buffer
    next_state = {:connected, :receiving_fixed_header}

    next_actions = [
      {:next_event, :internal, {:emit, package}},
      {:next_event, :internal, :consume_buffer}
    ]

    new_data = %{data | buffer: rest}
    {:next_state, next_state, new_data, next_actions}
  end

  def handle_event(:internal, :consume_buffer, {:connected, {:receiving_variable, _}}, _data) do
    # await more bytes
    :keep_state_and_data
  end

  # what should happen here?
  def handle_event(:internal, :consume_buffer, :disconnected, _data) do
    # we might be disconnected, but could we have data in the buffer still ?
    # perhaps we should consume that
    :keep_state_and_data
  end

  # receiving fixed header
  def handle_event(:internal, :consume_buffer, {:connected, :receiving_fixed_header}, data) do
    case parse_fixed_header(data.buffer) do
      {:ok, length} ->
        new_state = {:connected, {:receiving_variable, length}}
        next_actions = [{:next_event, :internal, :consume_buffer}]
        {:next_state, new_state, data, next_actions}

      :cont ->
        :keep_state_and_data

      {:error, :invalid_header_length} ->
        {:stop, {:protocol_violation, :invalid_header_length}}
    end
  end

  def handle_event(:internal, {:emit, package}, _, data) do
    send(data.parent, {:incoming, package})
    :keep_state_and_data
  end

  def handle_event({:call, from}, {:handle_socket, transport, socket}, :disconnected, data) do
    new_state = {:connected, :receiving_fixed_header}

    next_actions = [
      {:reply, from, {:ok, self()}},
      {:next_event, :internal, :activate_socket},
      {:next_event, :internal, :consume_buffer}
    ]

    # better reset the buffer
    new_data = %State{data | transport: transport, socket: socket, buffer: <<>>}

    {:next_state, new_state, new_data, next_actions}
  end

  def handle_event({:call, from}, {:handle_socket, _transport, _socket}, current_state, data) do
    next_actions = [{:reply, from, {:error, :not_ready}}]
    reason = {:got_socket_in_wrong_state, current_state}
    {:stop_and_reply, reason, next_actions, data}
  end

  # connect
  def handle_event(
        {:call, from},
        :connect,
        :disconnected,
        %State{
          transport: %Transport{type: transport, host: host, port: port, opts: opts}
        } = data
      ) do
    case transport.connect(host, port, opts, 10000) do
      {:ok, socket} ->
        new_state = {:connected, :receiving_fixed_header}

        next_actions = [
          {:reply, from, {:ok, {transport, socket}}},
          {:next_event, :internal, :activate_socket},
          {:next_event, :internal, :consume_buffer}
        ]

        # better reset the buffer
        new_data = %State{data | socket: socket, buffer: <<>>}
        {:next_state, new_state, new_data, next_actions}

      {:error, reason} ->
        next_actions = [{:reply, from, {:error, connection_error(reason)}}]
        {:next_state, :disconnected, data, next_actions}
    end
  end

  defp connection_error(reason) do
    case reason do
      {:options, {:cacertfile, []}} ->
        {:stop, :no_cacartfile_specified}

      :nxdomain ->
        {:retry, :nxdomain}

      :econnrefused ->
        {:retry, :econnrefused}
    end
  end

  defp parse_fixed_header(<<_::8, 0::1, length::7, _::binary>>) do
    {:ok, length + 2}
  end

  # 2 bytes
  defp parse_fixed_header(<<_::8, 1::1, a::7, 0::1, b::7, _::binary>>) do
    <<length::integer-size(14)>> = <<b::7, a::7>>
    {:ok, length + 3}
  end

  # 3 bytes
  defp parse_fixed_header(<<_::8, 1::1, a::7, 1::1, b::7, 0::1, c::7, _::binary>>) do
    <<length::integer-size(21)>> = <<c::7, b::7, a::7>>
    {:ok, length + 4}
  end

  # 4 bytes
  defp parse_fixed_header(<<_::8, 1::1, a::7, 1::1, b::7, 1::1, c::7, 0::1, d::7, _::binary>>) do
    <<length::integer-size(28)>> = <<d::7, c::7, b::7, a::7>>
    {:ok, length + 5}
  end

  defp parse_fixed_header(header) when byte_size(header) > 5 do
    {:error, :invalid_header_length}
  end

  defp parse_fixed_header(_) do
    :cont
  end
end
