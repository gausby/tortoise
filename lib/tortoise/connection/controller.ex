defmodule Tortoise.Connection.Controller do
  @moduledoc false

  require Logger

  alias Tortoise.{Package, Handler}

  use GenServer

  @enforce_keys [:client_id, :handler]
  defstruct client_id: nil,
            status: :down,
            awaiting: %{},
            handler: %Handler{module: Handler.Default, initial_args: []}

  alias __MODULE__, as: State

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    handler = Handler.new(Keyword.fetch!(opts, :handler))

    init_state = %State{
      client_id: client_id,
      handler: handler
    }

    GenServer.start_link(__MODULE__, init_state, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise.Registry.via_name(__MODULE__, client_id)
  end

  def stop(client_id) do
    GenServer.stop(via_name(client_id))
  end

  def info(client_id) do
    GenServer.call(via_name(client_id), :info)
  end

  # Server callbacks
  @impl true
  def init(%State{handler: handler} = opts) do
    {:ok, _} = Tortoise.Events.register(opts.client_id, :status)

    case Handler.execute(handler, :init) do
      {:ok, %Handler{} = updated_handler} ->
        {:ok, %State{opts | handler: updated_handler}}
    end
  end

  @impl true
  def terminate(reason, %State{handler: handler}) do
    _ignored = Handler.execute(handler, {:terminate, reason})
    :ok
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(
        {:onward, %Package.Publish{qos: 2, dup: false} = publish},
        %State{handler: handler} = state
      ) do
    case Handler.execute(handler, {:publish, publish}) do
      {:ok, updated_handler} ->
        {:noreply, %State{state | handler: updated_handler}}
    end
  end

  @impl true
  def handle_info({{Tortoise, client_id}, ref, result}, %{client_id: client_id} = state) do
    case {result, Map.pop(state.awaiting, ref)} do
      {_, {nil, _}} ->
        Logger.warn("Unexpected async result")
        {:noreply, state}

      {:ok, {_action, updated_awaiting}} ->
        {:noreply, %State{state | awaiting: updated_awaiting}}
    end
  end
end
