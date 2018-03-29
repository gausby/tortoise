defmodule Tortoise.Connection do
  @moduledoc false
  use Supervisor

  @connection_name __MODULE__

  def start_link() do
    Supervisor.start_link(__MODULE__, :na, name: @connection_name)
  end

  # Public API
  def connect({_protocol, _host, _port} = server, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :client_id, &generate_client_id/0)

    case Supervisor.start_child(@connection_name, [server, opts]) do
      {:ok, _pid} ->
        {:ok, Keyword.fetch!(opts, :client_id)}
        # todo, "already started"
    end
  end

  def disconnect(_client_id) do
    # Supervisor.terminate_child()
  end

  # Callbacks
  def init(:na) do
    children = [supervisor(Tortoise.Connection.Supervisor, [])]
    supervise(children, strategy: :simple_one_for_one)
  end

  # Helpers
  defp generate_client_id() do
    :crypto.strong_rand_bytes(10) |> Base.encode16()
  end
end
