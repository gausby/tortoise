defmodule Tortoise.Connection.Transmitter do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.Package

  @enforce_keys [:client_id]
  defstruct client_id: nil
  alias __MODULE__, as: State

  @type client_id :: pid() | term()

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    data = %State{client_id: client_id}
    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
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

  def stop(client_id) do
    GenStateMachine.stop(via_name(client_id))
  end

  @doc false
  def handle_socket(client_id, {transport, socket}) do
    GenStateMachine.call(via_name(client_id), {:handle_socket, {transport, socket}})
  end

  @doc false
  def cast(client_id, %{__struct__: _} = package) do
    data = Package.encode(package)
    GenStateMachine.cast(via_name(client_id), {:transmit, data})
  end

  # Server callbacks
  def init(data) do
    {:ok, :disconnected, data, []}
  end

  # Putting data on the wire
  def handle_event(:cast, {:transmit, package}, {:connected, transport, socket}, data) do
    case transport.send(socket, package) do
      :ok ->
        :keep_state_and_data

      {:error, :closed} ->
        {:next_state, :disconnected, data, :postpone}
    end
  end

  def handle_event(:cast, {:transmit, _package}, :disconnected, _data) do
    # postpone the data transmit for when we are online again
    {:keep_state_and_data, :postpone}
  end

  def handle_event({:call, from}, {:handle_socket, {transport, socket}}, _, data) do
    new_state = {:connected, transport, socket}
    next_actions = [{:reply, from, :ok}]
    {:next_state, new_state, data, next_actions}
  end
end
