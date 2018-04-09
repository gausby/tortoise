defmodule Tortoise.Connection do
  @moduledoc false
  use Supervisor

  alias Tortoise.Package

  @connection_name __MODULE__

  def start_link() do
    Supervisor.start_link(__MODULE__, :na, name: @connection_name)
  end

  # Public API
  def open({_protocol, _host, _port} = server, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :client_id, &generate_client_id/0)

    case Supervisor.start_child(@connection_name, [server, opts]) do
      {:ok, _pid} ->
        {:ok, Keyword.fetch!(opts, :client_id)}
        # todo, "already started"
    end
  end

  def close(_client_id) do
    # Supervisor.terminate_child()
  end

  def connect({protocol, host, port}, %Package.Connect{} = connect) do
    do_connect({protocol, host, port}, connect)
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

  defp do_connect({:tcp, host, port}, %Package.Connect{} = connect) do
    tcp_opts = [:binary, packet: :raw, active: false]

    with {:ok, socket} <- :gen_tcp.connect(host, port, tcp_opts),
         :ok = :gen_tcp.send(socket, Package.encode(connect)),
         {:ok, packet} <- :gen_tcp.recv(socket, 4, 5000) do
      case Package.decode(packet) do
        %Package.Connack{status: :accepted} = connack ->
          {:ok, socket, connack}

        %Package.Connack{status: {:refused, _reason}} = connack ->
          {:error, connack}

        otherwise ->
          violation = %{expected: Package.Connect, got: otherwise}
          {:error, {:protocol_violation, violation}}
      end
    else
      {:error, :econnrefused} ->
        {:stop, :econnrefused}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
