defmodule Tortoise.Connection.Transmitter do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.Package

  defstruct client_id: nil

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    data = %__MODULE__{client_id: client_id}
    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  def via_name(pid) when is_pid(pid), do: pid

  def via_name(client_id) do
    {:via, Registry, reg_name(client_id)}
  end

  def reg_name(client_id) do
    {Registry.Tortoise, {__MODULE__, client_id}}
  end

  def handle_socket(client_id, socket) do
    GenStateMachine.call(via_name(client_id), {:handle_socket, socket})
  end

  def ping(client_id) do
    pingreq = Package.encode(%Package.Pingreq{})
    GenStateMachine.cast(via_name(client_id), {:transmit, pingreq})
  end

  def cast(client_id, %{__struct__: _} = package) do
    data = Package.encode(package)
    GenStateMachine.cast(via_name(client_id), {:transmit, data})
  end

  # Server callbacks
  def init(data) do
    {:ok, :disconnected, data, []}
  end

  def handle_event({:call, from}, {:handle_socket, socket}, :disconnected, data) do
    new_state = {:connected, socket}
    next_actions = [{:reply, from, :ok}]
    {:next_state, new_state, data, next_actions}
  end

  def handle_event(:cast, {:transmit, package}, {:connected, socket}, _data) do
    case :gen_tcp.send(socket, package) do
      :ok ->
        :keep_state_and_data
    end
  end

  def handle_event(:cast, {:transmit, _package}, :disconnected, _data) do
    # postpone the data transmit for when we are online again
    {:keep_state_and_data, :postpone}
  end
end
