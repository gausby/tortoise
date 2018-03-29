defmodule Tortoise.InFlightRegistry do
  @moduledoc """
  A registry for storing the various ack messages we expect
  """

  use GenServer

  alias Tortoise.Package

  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec expect(binary(), Package.Puback.t()) :: :ok
  def expect(client_id, %Package.Puback{identifier: identifier}) do
    # put the expectation of a puback in the ets for the client id
    # key {{client_id, identifier}, :puback}
    :ets.insert_new(__MODULE__, {{client_id, identifier}})
  end

  # Server callbacks
  def init(state) do
    :ets.new(__MODULE__, [:set, :public, {:write_concurrency, true}])
    {:ok, state}
  end
end
